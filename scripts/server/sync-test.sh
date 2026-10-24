#!/usr/bin/env bash
# Fixed-target privileged maintenance action. Installed root:root 0755.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
SRC="$CANDIDATE"
DST="$TEST_DB"

cleanup() {
  local code=$?
  trap - EXIT
  if [[ -n "$SQLFILE" ]]; then
    rm -f -- "$SQLFILE" "${SQLFILE}.transaction"
  fi
  if [[ "$api_stopped" == 1 ]]; then
    if ! docker start "$API" >/dev/null; then
      echo 'CRITICAL: Test API failed to restart; check Docker immediately' >&2
      exit 1
    fi
  fi
  exit "$code"
}

validate_schema() {
  local table_names expected_tables name source_columns test_columns
  # Fail closed on unexpected schema drift; never guess which new tables to copy.
  table_names="$(q_file "$SRC" business-tables.sql)"
  expected_tables="$(q_file "$SRC" expected-business-tables.sql)"
  if [[ -z "$expected_tables" || "$table_names" != "$expected_tables" ]]; then
    printf 'ERROR: Source tables differ from the reviewed transfer set.\nExpected:\n%s\nActual:\n%s\n' "$expected_tables" "$table_names" >&2
    exit 1
  fi
  TABLES=()
  while IFS= read -r name; do TABLES+=("$name"); done <<< "$table_names"
  for name in "${TABLES[@]}"; do
    [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || { echo 'ERROR: Unsafe table identifier' >&2; exit 1; }
    [[ "$(q "$DST" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='$name'")" == 1 ]] || { echo "ERROR: Missing test table: $name" >&2; exit 1; }
  done

  # Compare transfer-relevant table structures (columns, types, nullability,
  # generated/identity flags). Database-local Liquibase history is independent.
  source_columns="$(q_file "$SRC" table-columns.sql)"
  test_columns="$(q_file "$DST" table-columns.sql)"
  [[ "$source_columns" == "$test_columns" ]] || fail 'Source/test table columns differ; refusing sync'
  # Preserve Liquibase execution history exactly (not merely a positive count).
  CHANGELOG_BEFORE="$(q_file "$DST" liquibase-fingerprint.sql)"
}

create_backup() {
  local stamp backup
  [[ "$(docker inspect -f '{{.State.Running}}' "$API")" == true ]] || { echo 'ERROR: Test API must be running before sync' >&2; exit 1; }
  install -d -o "$PG_ADMIN_USER" -g "$PG_ADMIN_USER" -m 700 "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_DIR/workouts_test_before_sync_$stamp.dump"
  SQLFILE="$(mktemp /tmp/workouts-sync.XXXXXXXX.sql)"
  chown "$PG_ADMIN_USER:$PG_ADMIN_USER" "$SQLFILE"
  chmod 600 "$SQLFILE"
  api_stopped=0

  # Recoverable on-host backup BEFORE any destructive test operation.
  pg "$PG/pg_dump" -h "$PG_SOCKET" -p "$PG_PORT" -Fc -f "$backup" -d "$DST"
  pg "$PG/pg_restore" --list "$backup" >/dev/null
  echo "Test database backup verified: $backup"
}

export_candidate() {
  local name
  local -a args=()
  # The users/coaches INSERT triggers rebuild account_login_identifiers.
  # Keep the table in the TRUNCATE set, but never insert its source rows again:
  # doing so violates account_login_identifiers_pkey.
  # All other reviewed business tables are copied from the candidate.
  for name in "${TABLES[@]}"; do
    if [[ "$name" == 'account_login_identifiers' ]]; then
      continue
    fi
    args+=(--table="public.$name")
  done
  pg "$PG/pg_dump" -h "$PG_SOCKET" -p "$PG_PORT" -d "$SRC" --data-only --column-inserts --no-owner --no-acl "${args[@]}" -f "$SQLFILE"
  [[ -s "$SQLFILE" ]] || { echo 'ERROR: Empty transfer data' >&2; exit 1; }
}

apply_transfer() {
  local table_sql
  # Stop writes by the test API, then atomically truncate/reload.
  echo 'Stopping test workouts-api container during sync.'
  api_stopped=1
  docker stop --time 30 "$API" >/dev/null
  table_sql="$(printf 'public.%s, ' "${TABLES[@]}")"
  table_sql="${table_sql%, }"
  # A single TRUNCATE covers interdependent FK tables without CASCADE.
  # Any referencing table outside the set causes failure and full rollback.
  {
    printf "SET LOCAL lock_timeout = '15s';\nSET LOCAL statement_timeout = '15min';\n"
    printf 'TRUNCATE TABLE %s RESTART IDENTITY;\n' "$table_sql"
    # Remove pg_dump's empty search_path setting so triggers can resolve public tables.
    sed "/^SELECT pg_catalog.set_config('search_path', '', false);$/d" "$SQLFILE"
    # Production login state must not become valid in test.
    printf "\\i %s/sql/clear-test-auth.sql\n" "$BASE"
    # All owned serial/identity sequences are reconciled to imported row IDs.
    printf "\\i %s/sql/reconcile-sequences.sql\n" "$BASE"
    printf "\\i %s/sql/assert-cleared.sql\n" "$BASE"
  } > "${SQLFILE}.transaction"
  chown "$PG_ADMIN_USER:$PG_ADMIN_USER" "${SQLFILE}.transaction"
  chmod 600 "${SQLFILE}.transaction"
  # psql --single-transaction ensures the entire SQL file is committed or rolled back.
  pg "$PG/psql" -X -v ON_ERROR_STOP=1 -q -1 -h "$PG_SOCKET" -p "$PG_PORT" -d "$DST" -f "${SQLFILE}.transaction"
  rm -f -- "${SQLFILE}.transaction"
}

verify_transfer() {
  local source_fingerprints test_fingerprints changelog_after
  # Compare all copied/rebuilt tables, including row content and duplicates.
  # Deliberately cleared security/mail tables are verified empty separately.
  source_fingerprints="$(q_file "$SRC" table-fingerprints.sql)"
  test_fingerprints="$(q_file "$DST" table-fingerprints.sql)"
  [[ -n "$source_fingerprints" && "$source_fingerprints" == "$test_fingerprints" ]] || fail 'Transferred table contents differ; candidate preserved'
  q_file "$DST" assert-cleared.sql >/dev/null
  changelog_after="$(q_file "$DST" liquibase-fingerprint.sql)"
  [[ "$CHANGELOG_BEFORE" == "$changelog_after" ]] || {
    echo 'ERROR: Liquibase changelog was modified; candidate preserved' >&2; exit 1;
  }
}

clear_candidate() {
  # Only after the test transaction COMMITTED, clear the candidate for reuse.
  # Transactional DDL: all schema objects are removed together or none are.
  # Keep the dblink extension preinstalled so the non-superuser restore loader
  # can restore the next production dump without CREATE EXTENSION privileges.
  # The restored test DB and its durable on-host backup are untouched here.
  echo 'Test sync committed; clearing candidate for the next pipeline.'
  pg "$PG/psql" -X -v ON_ERROR_STOP=1 -q -1 -h "$PG_SOCKET" -p "$PG_PORT" -v candidate_db="$CANDIDATE" -d "$SRC" -f "$BASE/sql/reset-candidate.sql"
  echo 'Candidate cleared; dblink remains available for the next restore.'
}

main() {
  require_root
  lock_candidate
  SQLFILE=''
  api_stopped=0
  trap cleanup EXIT
  validate_schema
  create_backup
  export_candidate
  apply_transfer
  verify_transfer
  clear_candidate
  echo "Test database sync succeeded: ${#TABLES[@]} source tables, preserved Liquibase and test-only tables."
  echo 'Production sessions, login attempts and outgoing password-reset and registration mail queues cleared in test.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
