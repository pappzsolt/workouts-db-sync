SET TIME ZONE 'UTC';
\ir cleared-tables.sql
CREATE OR REPLACE FUNCTION pg_temp.sync_fingerprints()
RETURNS TABLE(tablename text, row_count bigint, fingerprint text) LANGUAGE plpgsql AS $body$
DECLARE t record;
BEGIN
  FOR t IN SELECT p.tablename FROM pg_tables p WHERE p.schemaname='public'
    AND p.tablename NOT IN ('databasechangelog','databasechangeloglock','login_rate_limits')
    AND NOT EXISTS (SELECT 1 FROM sync_cleared_tables c WHERE c.tablename=p.tablename)
    ORDER BY p.tablename COLLATE "C"
  LOOP
    RETURN QUERY EXECUTE format(
      $query$SELECT %L::text, count(*), md5(coalesce(string_agg(row_hash, '' ORDER BY row_hash COLLATE "C"), '')) FROM (SELECT md5(to_jsonb(t)::text) AS row_hash FROM public.%I t) hashes$query$,
      t.tablename,t.tablename);
  END LOOP;
END;
$body$;
SELECT * FROM pg_temp.sync_fingerprints();
