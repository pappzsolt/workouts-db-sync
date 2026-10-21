SELECT
  (SELECT count(*) FROM pg_class c
   JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
     AND NOT EXISTS (
       SELECT 1 FROM pg_depend d
       WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')),
  (SELECT count(*) FROM pg_proc p
   JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND NOT EXISTS (
       SELECT 1 FROM pg_depend d
       WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')),
  (SELECT count(*) FROM pg_extension WHERE extname='dblink');
