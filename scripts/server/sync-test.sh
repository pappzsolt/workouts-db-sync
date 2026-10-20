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
# Preserve Liquibase execution history exactly (not merely a positive count).
CHANGELOG_BEFORE="$(q "$DST" "SELECT md5(coalesce(string_agg(row_to_json(t)::text,E'\n' ORDER BY t.orderexecuted, t.id, t.author),'')) FROM public.databasechangelog t")"

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
  cat /usr/local/libexec/workouts-db-sync/sql/reconcile-sequences.sql
} > "${SQLFILE}.transaction"
chown postgres:postgres "${SQLFILE}.transaction"
chmod 600 "${SQLFILE}.transaction"
# psql --single-transaction ensures the entire SQL file is committed or rolled back.
pg "$PG/psql" -X -v ON_ERROR_STOP=1 -q -1 -d "$DST" -f "${SQLFILE}.transaction"
rm -f -- "${SQLFILE}.transaction"
# Verify three representative business tables match before candidate is cleared.
for name in users workouts exercises; do
  [[ "$(q "$SRC" "SELECT count(*) FROM public.$name")" == "$(q "$DST" "SELECT count(*) FROM public.$name")" ]] || {
    echo "ERROR: Count mismatch after sync: $name; candidate preserved" >&2; exit 1;
  }
done
[[ "$CHANGELOG_BEFORE" == "$(q "$DST" "SELECT md5(coalesce(string_agg(row_to_json(t)::text,E'\n' ORDER BY t.orderexecuted, t.id, t.author),'')) FROM public.databasechangelog t")" ]] || {
  echo 'ERROR: Liquibase changelog was modified; candidate preserved' >&2; exit 1;
}

# Only after the test transaction COMMITTED, clear the candidate for reuse.
# Transactional DDL: all schema objects are removed together or none are.
# Keep the dblink extension preinstalled so the non-superuser restore loader
# can restore the next production dump without CREATE EXTENSION privileges.
# The restored test DB and its durable on-host backup are untouched here.
echo 'Test sync committed; clearing candidate for the next pipeline.'
pg "$PG/psql" -X -v ON_ERROR_STOP=1 -q -1 -d "$SRC" -c "
BEGIN;
DROP SCHEMA public CASCADE;
CREATE SCHEMA public AUTHORIZATION pg_database_owner;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA public;
DO \$verify\$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','S','f')
  ) THEN
    RAISE EXCEPTION 'Candidate cleanup left database objects';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_depend d
        WHERE d.classid='pg_catalog.pg_proc'::regclass
          AND d.objid=p.oid AND d.deptype='e'
      )
  ) THEN
    RAISE EXCEPTION 'Candidate cleanup left non-extension routines';
  END IF;
END;
\$verify\$;
COMMIT;
"
echo 'Candidate cleared; dblink remains available for the next restore.'

echo "Test database sync succeeded: ${#TABLES[@]} source tables, preserved Liquibase and test-only tables."
echo 'Production sessions, login attempts and outgoing password-reset mail queue cleared in test.'
