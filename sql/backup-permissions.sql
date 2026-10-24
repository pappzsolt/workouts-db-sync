SELECT set_config('workouts_sync.backup_role', :'backup_role', false);
DO $grants$
DECLARE backup_role text := current_setting('workouts_sync.backup_role'); owner_role record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=backup_role) THEN
    RAISE EXCEPTION 'Backup role % must already exist', backup_role;
  END IF;
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',current_database(),backup_role);
  EXECUTE format('GRANT USAGE ON SCHEMA public TO %I',backup_role);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I',backup_role);
  EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO %I',backup_role);
  FOR owner_role IN SELECT DISTINCT tableowner FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',owner_role.tableowner,backup_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON SEQUENCES TO %I',owner_role.tableowner,backup_role);
  END LOOP;
END;
$grants$;
