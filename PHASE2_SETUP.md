# Phase 2 – manual setup

This repository contains manually triggered CI jobs for provisioning a restricted production backup entrypoint and verifying a PostgreSQL custom-format dump. It does **not** restore test data yet.

## Required access

- `PROD_BACKUP_SSH_KEY`: GitLab **file-type**, protected variable holding the private key whose public key is permitted as a forced command for `workouts-db-backup` on production.
- `PROD_SSH_KNOWN_HOSTS`: GitLab **file-type**, protected variable containing a *previously verified* host key for `2.29.51.66`. Do not learn the host key at job runtime using unauthenticated `ssh-keyscan`.
- `PROD_DEPLOY_SSH_KEY`: GitLab **file-type**, protected variable for a separate one-time deploy identity.
- `PROD_DEPLOY_USER`: SSH account with permission to run **only** an independently reviewed privileged installer command.
- `PROD_BACKUP_PUBLIC_KEY`: Public key matching `PROD_BACKUP_SSH_KEY`.

Set `main` as a protected branch and restrict who may launch these manual jobs. Use masked/hidden variables when supported, and never log secrets.

## Bootstrap limitation

A GitLab job cannot securely install a root-owned executable or update another user's `authorized_keys` from the currently available `workouts-db-backup` account: its forced command is `/usr/bin/false`. **The production administrator must first authorize a narrow bootstrap mechanism**, such as a reviewed root-owned installer at `/usr/local/sbin/workouts-db-backup-install`, callable by the deploy identity via narrowly scoped passwordless sudo. Do not add the deploy or backup account to the Docker group and do not grant general `sudo` privileges.

**The provision job is intentionally blocked until the narrow installer exists.** The supplied provisioning script assumes the installer collects two staged inputs from `/tmp/production-backup.sh` and `/tmp/backup.pub`; this staging path must be hardened in the installer (ownership and symlink checks, atomic installation, fixed paths) before enabling the job. Because an unsafe privileged installer would undermine the access restrictions, review and authorize that implementation separately.

Until provisioned, the backup verification job also cannot succeed because the SSH forced command remains `/usr/bin/false`.

Production archive contents are sensitive. The verification job neither logs the dump nor publishes it as a GitLab artifact. The final sync implementation must use encrypted transport, carefully scoped temporary files, and decide on sanitization/token revocation before starting the test API.
