#!/usr/bin/env bash
# Fixed-target maintenance action. Only runs via restricted SSH -> sudo.
set -Eeuo pipefail
[[ "$(id -u)" == 0 ]] || { echo 'ERROR: root required' >&2; exit 1; }
PG='/usr/lib/postgresql/17/bin'
TARGET='workouts_restore_candidate'
LOCK='/run/lock/workouts-db-sync-test.lock'
exec 9>"$LOCK"
flock -n 9 || { echo 'ERROR: Candidate maintenance or test sync in progress' >&2; exit 1; }

# This operation is intentionally limited to the candidate database.
# Reject an unexpected populated candidate: never silently throw away a
# successfully restored backup after a failed test sync.
runuser -u postgres -- "$PG/psql" -X -q -v ON_ERROR_STOP=1 -1 -d "$TARGET" <<'SQL'
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

-- Remove leftover views, sequences, routines, types and their dependencies.
-- Dropping public also removes dblink; reinstall it as a trusted admin.
DROP SCHEMA public CASCADE;
CREATE SCHEMA public AUTHORIZATION pg_database_owner;
CREATE EXTENSION dblink WITH SCHEMA public;

DO $verify$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_depend d
        WHERE d.classid='pg_catalog.pg_proc'::regclass
          AND d.objid=p.oid AND d.deptype='e'
      )
  ) THEN
    RAISE EXCEPTION 'Candidate preparation left residual objects';
  END IF;
END;
$verify$;
SQL
echo 'Candidate prepared: no business tables, routines or sequences; dblink installed.'
