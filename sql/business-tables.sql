SELECT tablename
FROM pg_catalog.pg_tables
WHERE schemaname = 'public'
  AND tablename NOT IN ('databasechangelog', 'databasechangeloglock', 'login_rate_limits')
ORDER BY tablename COLLATE "C";
