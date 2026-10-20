# GitLab-managed Ansible bootstrap

Starting a **web/main pipeline** automatically runs `ansible_bootstrap` first,
then the existing verification, restore and test synchronization jobs in order.
No manual steps on budsh are required once CI access is configured.

## One-time GitLab CI/CD variables (required, never commit private keys)

- `ANSIBLE_BOOTSTRAP_SSH_KEY`: **File**, private SSH key accepted by the existing
  `pappzs` administrative account on budsh.
- `ANSIBLE_BOOTSTRAP_KNOWN_HOSTS`: **File**, verified SSH host key for budsh.
- `ANSIBLE_BECOME_PASSWORD`: **Masked**, sudo password for `pappzs` on budsh,
  unless account is configured with passwordless sudo (still required in this
  implementation). Keep protected and never output it.
- Existing `TEST_RESTORE_SSH_KEY`, `TEST_RESTORE_SSH_KNOWN_HOSTS`,
  `PROD_BACKUP_SSH_KEY`, `PROD_SSH_KNOWN_HOSTS`, `TEST_DB_PASSWORD` continue
  to be required for later pipeline jobs.

The bootstrap installs the dedicated SSH receiver, fixed-purpose root scripts,
sudoers rule, candidate DB/role, dblink and a narrow PostgreSQL HBA/ident map.
It does not install PostgreSQL itself, Docker, the application, or configure the
production server. **A completely bare OS cannot be provisioned by this repo**:
PostgreSQL 17, Docker, workouts-api, an SSH-accessible sudo-capable administrative
account, and the production read-only SSH backup endpoint must already exist.
The GitLab runner must reach budsh via TCP/22, and CI variables must be supplied
in GitLab before the first pipeline. PostgreSQL database changes are confined
to `workouts_restore_candidate` during bootstrap.

No database dumps are stored as GitLab artifacts. Server-side `sync-test.sh`
retains the pre-sync `workouts_test` backup in `/var/backups/workouts-db-sync`.
