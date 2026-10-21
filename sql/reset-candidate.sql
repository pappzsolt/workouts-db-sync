-- Call only after the preparation guard or a successfully committed test sync.
-- The caller supplies a single transaction and connects to the candidate only.
DO $guard$
BEGIN
  IF current_database() <> 'workouts_restore_candidate' THEN
    RAISE EXCEPTION 'Candidate cleanup cannot run in this database';
  END IF;
END;
$guard$;

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
    RAISE EXCEPTION 'Candidate cleanup left residual objects';
  END IF;
END;
$verify$;
