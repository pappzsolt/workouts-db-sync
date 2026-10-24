\ir cleared-tables.sql
DO $clear$
DECLARE names text;
BEGIN
  SELECT string_agg(format('public.%I', tablename), ', ') INTO names FROM sync_cleared_tables;
  EXECUTE 'TRUNCATE TABLE ' || names || ' RESTART IDENTITY';
END;
$clear$;
