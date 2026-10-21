#!/usr/bin/env bash
# Fixed-target maintenance action. Only runs via restricted SSH -> sudo.
set -Eeuo pipefail
source /usr/local/libexec/workouts-db-sync/common.sh
require_root
lock_candidate

# This operation is intentionally limited to the candidate database.
# Reject an unexpected populated candidate: never silently throw away a
# successfully restored backup after a failed test sync.
pg "$PG/psql" -X -q -v ON_ERROR_STOP=1 -1 -d "$CANDIDATE" <<'SQL'
DO $check$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','p','f')
  ) THEN
    RAISE EXCEPTION 'Candidate has business tables; refusing to clear it';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace
    WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema')
      AND nspname NOT LIKE 'pg_toast%'
      AND nspname NOT LIKE 'pg_temp_%'
  ) THEN
    RAISE EXCEPTION 'Candidate has an unexpected schema; refusing to clear it';
  END IF;
END;
$check$;

\i /usr/local/libexec/workouts-db-sync/sql/reset-candidate.sql
SQL
echo 'Candidate prepared: no business tables, routines or sequences; dblink installed.'
