CREATE OR REPLACE TEMP VIEW sync_cleared_tables AS
SELECT tablename FROM (VALUES
  ('auth_login_attempts'),
  ('login_audit_logs'),
  ('password_reset_tokens'),
  ('password_reset_email_outbox'),
  ('registration_email_outbox'),
  ('refresh_token_revocations'),
  ('refresh_token_families'),
  ('account_token_versions')
) AS cleared(tablename);
