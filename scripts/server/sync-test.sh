#!/usr/bin/env bash
# Fixed-target privileged maintenance action. Installed root:root 0755.
set -Eeuo pipefail
umask 077
[[ "$(id -u)" == 0 ]] || { echo 'ERROR: root required' >&2; exit 1; }
PG='/usr/lib/postgresql/17/bin'
SRC='workouts_restore_candidate'
DST='workouts_test'
BACKUP_DIR='/var/backups/workouts-db-sync'
LOCK='/run/lock/workouts-db-sync-test.lock'
API='workouts-api'
exec 9>"$LOCK"
flock -n 9 || { echo 'ERROR: Another test sync is running' >&2; exit 1; }

# Exactly these three test-system tables must never be copied from production.
EXCLUDE=(databasechangelog databasechangeloglock login_rate_limits)
pg() { runuser -u postgres -- "$@"; }
q() { pg "$PG/psql" -X -A -t -q -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }

# Fail closed on unexpected schema drift; never guess which new tables to copy.
mapfile -t TABLES < <(q "$SRC" "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename NOT IN ('databasechangelog','databasechangeloglock','login_rate_limits') ORDER BY tablename")
[[ "${#TABLES[@]}" == 28 ]] || { echo "ERROR: Expected 28 source tables; found ${#TABLES[@]}" >&2; exit 1; }
for name in "${TABLES[@]}"; do
  [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || { echo 'ERROR: Unsafe table identifier' >&2; exit 1; }
  [[ "$(q "$DST" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='$name'")" == 1 ]] || { echo "ERROR: Missing test table: $name" >&2; exit 1; }
done

# Compare transfer-relevant table structures (columns, types, nullability,
# generated/identity flags). Database-local Liquibase history is independent.
COLUMN_SQL="SELECT md5(string_agg(format('%s:%s:%s:%s:%s:%s',c.relname,a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attgenerated,a.attidentity), E'\\n' ORDER BY c.relname,a.attnum)) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped AND c.relname NOT IN ('databasechangelog','databasechangeloglock','login_rate_limits')"
[[ "$(q "$SRC" "$COLUMN_SQL")" == "$(q "$DST" "$COLUMN_SQL")" ]] || { echo 'ERROR: Source/test table columns differ; refusing sync' >&2; exit 1; }

[[ "$(docker inspect -f '{{.State.Running}}' "$API")" == true ]] || { echo 'ERROR: Test API must be running before sync' >&2; exit 1; }
install -d -o postgres -g postgres -m 700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_DIR/workouts_test_before_sync_$STAMP.dump"
SQLFILE="$(mktemp /tmp/workouts-sync.XXXXXXXX.sql)"
chown postgres:postgres "$SQLFILE"
chmod 600 "$SQLFILE"
api_stopped=0
cleanup() {
  code=$?
  trap - EXIT
  rm -f -- "$SQLFILE" "${SQLFILE}.transaction"
  if [[ "$api_stopped" == 1 ]]; then
    if ! docker start "$API" >/dev/null; then
      echo 'CRITICAL: Test API failed to restart; check Docker immediately' >&2
      exit 1
    fi
  fi
  exit "$code"
}
trap cleanup EXIT

# Recoverable on-host backup BEFORE any destructive test operation.
pg "$PG/pg_dump" -Fc -f "$BACKUP" -d "$DST"
pg "$PG/pg_restore" --list "$BACKUP" >/dev/null
echo "Test database backup verified: $BACKUP"

# The users/coaches INSERT triggers rebuild account_login_identifiers.
# Keep the table in the TRUNCATE set, but never insert its source rows again:
# doing so violates account_login_identifiers_pkey.
# The other 27 business tables are copied from the candidate.
ARGS=()
for name in "${TABLES[@]}"; do
  if [[ "$name" == 'account_login_identifiers' ]]; then
    continue
  fi
  ARGS+=(--table="public.$name")
done
pg "$PG/pg_dump" -d "$SRC" --data-only --column-inserts --no-owner --no-acl "${ARGS[@]}" -f "$SQLFILE"
[[ -s "$SQLFILE" ]] || { echo 'ERROR: Empty transfer data' >&2; exit 1; }

# Stop writes by the test API, then atomically truncate/reload.
echo 'Stopping test workouts-api container during sync.'
docker stop --time 30 "$API" >/dev/null
api_stopped=1
TABLE_SQL="$(printf 'public.%s, ' "${TABLES[@]}")"
TABLE_SQL="${TABLE_SQL%, }"
# A single TRUNCATE covers interdependent FK tables without CASCADE.
# Any referencing table outside the set causes failure and full rollback.
{
  printf "SET LOCAL lock_timeout = '15s';\nSET LOCAL statement_timeout = '15min';\n"
  printf 'TRUNCATE TABLE %s RESTART IDENTITY;\n' "$TABLE_SQL"
  # Remove pg_dump's empty search_path setting so triggers can resolve public tables.
  sed "/^SELECT pg_catalog.set_config('search_path', '', false);$/d" "$SQLFILE"
  # Production login state must not become valid in test.
  printf '\nTRUNCATE TABLE public.auth_login_attempts, public.login_audit_logs, public.password_reset_tokens, public.password_reset_email_outbox, public.refresh_token_revocations, public.refresh_token_families, public.account_token_versions RESTART IDENTITY;\n'
  # All owned serial/identity sequences are reconciled to imported row IDs.
  cat <<'SEQSQL'
DO $sync$
DECLARE r record; max_id bigint;
BEGIN
  FOR r IN
    SELECT sn.nspname AS seqschema, seq.relname AS seqname,
           tn.nspname AS tblschema, tbl.relname AS tblname, a.attname AS colname
    FROM pg_class seq
    JOIN pg_namespace sn ON sn.oid=seq.relnamespace
    JOIN pg_depend dep ON dep.objid=seq.oid AND dep.deptype IN ('a','i')
    JOIN pg_class tbl ON tbl.oid=dep.refobjid
    JOIN pg_namespace tn ON tn.oid=tbl.relnamespace
    JOIN pg_attribute a ON a.attrelid=tbl.oid AND a.attnum=dep.refobjsubid
    WHERE seq.relkind='S' AND sn.nspname='public' AND tn.nspname='public'
      AND tbl.relname NOT IN ('databasechangelog','databasechangeloglock','login_rate_limits')
  LOOP
    EXECUTE format('SELECT max(%I) FROM %I.%I',r.colname,r.tblschema,r.tblname) INTO max_id;
    IF max_id IS NULL THEN
      PERFORM pg_catalog.setval(format('%I.%I',r.seqschema,r.seqname)::regclass, 1, false);
    ELSE
      PERFORM pg_catalog.setval(format('%I.%I',r.seqschema,r.seqname)::regclass, max_id, true);
    END IF;
  END LOOP;
END;
$sync$;
SEQSQL
} > "${SQLFILE}.transaction"
chown postgres:postgres "${SQLFILE}.transaction"
chmod 600 "${SQLFILE}.transaction"
# psql --single-transaction ensures the entire SQL file is committed or rolled back.
pg "$PG/psql" -X -v ON_ERROR_STOP=1 -q -1 -d "$DST" -f "${SQLFILE}.transaction"
rm -f -- "${SQLFILE}.transaction"

echo "Test database sync succeeded: ${#TABLES[@]} source tables, preserved Liquibase and test-only tables."
echo 'Production sessions, login attempts and outgoing password-reset mail queue cleared in test.'
