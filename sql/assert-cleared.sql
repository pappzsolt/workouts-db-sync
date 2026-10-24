\ir cleared-tables.sql
DO $verify$
DECLARE t record; populated boolean;
BEGIN
  FOR t IN SELECT tablename FROM sync_cleared_tables LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I)', t.tablename) INTO populated;
    IF populated THEN RAISE EXCEPTION 'Security/mail table % was not cleared', t.tablename; END IF;
  END LOOP;
END;
$verify$;
