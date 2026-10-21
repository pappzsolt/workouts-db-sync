SELECT md5(string_agg(
  format('%s:%s:%s:%s:%s:%s', c.relname, a.attname,
         format_type(a.atttypid, a.atttypmod), a.attnotnull,
         a.attgenerated, a.attidentity),
  E'\n' ORDER BY c.relname, a.attnum))
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  AND a.attnum > 0 AND NOT a.attisdropped
  AND c.relname NOT IN ('databasechangelog', 'databasechangeloglock', 'login_rate_limits');
