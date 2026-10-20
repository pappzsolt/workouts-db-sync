# Phase 2 – production backup verification via GitLab CI/CD

The production backup command `/usr/local/bin/workouts-db-backup` is already installed on `hevsrv01`, and the `workouts-db-backup` SSH key is restricted to that command. **Do not run any provisioning job.** Only the manually launched `verify_production_backup` job connects to production, reads a `pg_dump -Fc` archive, verifies that `pg_restore --list` can parse the archive, and deletes the temporary archive at job exit. It does not restore the test database, upload a dump as an artifact, or modify production.

## GitLab settings (workouts/workouts-db-sync)

Protect the `main` branch and limit who can run the manual job. Add these CI/CD variables at **Settings → CI/CD → Variables**:

- `PROD_BACKUP_SSH_KEY`: **File** type, **Protected**. Contents: the dedicated private key corresponding to `/home/workouts-db-backup/.ssh/authorized_keys` on `hevsrv01`. Avoid printing or pasting it into logs or chat. File-type variables point to a temporary file in the CI job; this is intentionally **not** an SSH path on budsh.
- `PROD_SSH_KNOWN_HOSTS`: **File** type, **Protected**. Contents: the verified `2.29.51.66` SSH host key entry. Verify its fingerprint independently against `hevsrv01` before adding it; do **not** trust a first-contact `ssh-keyscan` from CI.

The repository already provides `PROD_HOST=2.29.51.66`. The verification job uses the key via `ssh -T` with strict host-key checking and a fixed `workouts-db-backup` remote username. Keep the existing restricted forced SSH command; no sudo/Docker access is required in the CI job.

## Run

Start a new pipeline manually for protected `main`, then run `verify_production_backup`. Success prints `Production backup verified` and archive size, not the archive contents. Do not enable GitLab debug tracing for this job.

**Limits:** `pg_restore --list` checks the archive structure, not a full test restore. The production data can contain private and authentication information; a later sync stage must plan isolation, sanitization, token revocation and outbound-email blocking before enabling the test API.
