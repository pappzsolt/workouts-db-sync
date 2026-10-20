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
