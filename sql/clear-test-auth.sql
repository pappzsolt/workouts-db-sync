TRUNCATE TABLE public.auth_login_attempts,
               public.login_audit_logs,
               public.password_reset_tokens,
               public.password_reset_email_outbox,
               public.refresh_token_revocations,
               public.refresh_token_families,
               public.account_token_versions
RESTART IDENTITY;
