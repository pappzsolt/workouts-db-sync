# GitLab-managed Ansible bootstrap

Starting a **web/main pipeline** runs preflight validation before `ansible_bootstrap`,
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
in GitLab before the first pipeline. Bootstrap prepares `workouts_restore_candidate` and maintains read-only backup
grants on `workouts_test`, including defaults for current table-owner roles.
It does not modify production.

No database dumps are stored as GitLab artifacts. Server-side `sync-test.sh`
retains the pre-sync `workouts_test` backup in `/var/backups/workouts-db-sync`.

## Refactored Ansible execution

- `scripts/ansible_run.py preflight` validates all 11 required GitLab CI/CD variables before `ansible/preflight.yml` checks repository policy, fixed database targets and SSH TCP reachability locally, without logging into either server.
- `ansible/bootstrap.yml` provisions the existing PostgreSQL 17 test server via a restricted administrative CI identity.
- `ansible/verify-result.yml` performs **read-only** post-sync checks of the candidate cleanup, preserved `dblink`, test data, Liquibase records and API status.
- `scripts/ansible_run.py` is the credential/SSH launcher for the two remote Ansible playbooks.

Bootstrap imports four task files from `ansible/tasks/bootstrap/`: prerequisites,
receiver/SSH installation, PostgreSQL configuration and installation verification.
Copy sources and SQL lookups use `playbook_dir`, so moving tasks does not change
asset resolution. All reviewed SQL files under `sql/` are installed root-owned
and read-only. Read-only post-sync queries use the same version-controlled assets
through controller lookups and PostgreSQL stdin.

`ansible/vars/postgresql.yml` defines the administrative PostgreSQL argument
prefix shared by bootstrap, verification and reload. Each task still specifies
its database and SQL explicitly; the restricted receiver connection stays
separate. Preflight checks all four database names are distinct and validates
both inventory endpoints through the same assertion loop.

Server jobs run in `ci/sync.yml`, started under the parent pipeline's exclusive
`refresh_test_database` trigger. Both push and web pipelines run all server jobs
automatically in order; the resource remains reserved until the child finishes.

Preflight tasks have `policy` and `connectivity` tags. With a generated inventory
and the CI environment available, `ansible-playbook -i <inventory>
ansible/preflight.yml --tags policy` validates repository/database policy without
opening network connections. CI runs both groups by default.

The Python sync client and fixed-purpose server scripts use SSH forced commands and narrow sudo permissions. Do not replace them with general-purpose administrative Ansible connections during actual data transfer.

## Production inventory and security boundary

The launcher generates a temporary inventory from `PROD_HOST` and `TEST_HOST`.
The production backup SSH user has a
**forced command** and cannot execute Ansible modules or arbitrary shell.
Ansible preflight checks production SSH reachability, but actual production
backup still uses the existing restricted, read-only SSH stream.

This is **not** bare-metal provisioning of production. To build a new
production host from zero, provision its PostgreSQL/Docker stack and establish
a separately authorized infrastructure admin SSH identity first. Do not reuse
the backup identity or grant it unrestricted SSH/sudo.

Runtime configuration is rendered root-owned from `config/sync.yml`. See
[configuration and recovery](../docs/CONFIGURATION.md) for the shared dump-size
limit, mandatory Docker health check, and snapshot-first candidate recovery tool.
