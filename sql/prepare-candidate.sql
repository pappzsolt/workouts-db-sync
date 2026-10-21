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

\ir reset-candidate.sql
