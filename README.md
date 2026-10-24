# Workouts DB Sync

GitLab CI/CD + Ansible orchestration for production-to-test PostgreSQL 17 data sync.

- **Production:** `PROD_HOST` from GitLab CI/CD variables, `workouts`, read-only forced-command SSH backup.
- **Test:** `TEST_HOST` from GitLab CI/CD variables, `workouts_restore_candidate` → `workouts_test`.
- **Infrastructure:** Ansible provisions test receiver, restricted loader and candidate.
- **Safety:** Push and web pipelines on main run automatically after validation. Liquibase and test-specific tables are preserved. Test DB is backed up on `budsh` before sync.

The fixed-purpose receiver and transactional sync scripts intentionally remain
shell-based to retain the forced-command security boundary. This repository
does **not** bootstrap a bare production OS; existing production read-only SSH
backup access must be configured separately. See `ansible/README.md`.

### GitLab-side sync client (Python)

The six client-side backup/transfer/restore invocations share `scripts/db_sync.py`.
Its commands are `verify-production`, `backup-test`, `verify-transport`,
`prepare-candidate`, `restore-candidate`, and `sync-test`. SSH commands are
argument arrays (not shell snippets); GitLab File variables are copied into a
private temporary directory and removed when the job ends. Database archives
are never stored as GitLab artifacts. The production SSH key is still bound to
its server-side forced read-only command. The test SSH key is still bound to
its server-side allowlisted dispatcher. Ansible remains responsible for
server provisioning, and the existing SQL/transactional restoration logic is
unchanged.

Shared CI input validation, credential copies and SSH options live in
`scripts/ci.py`. Immutable SSH identity records define each username and its
GitLab key/known-hosts variables once, shared by inventory and transfer clients.
The Ansible launcher resolves playbooks from the project directory independently
of the caller's working directory. Interrupted transfers terminate and reap both
subprocesses, including when the receiver cannot be started.
The root-owned `scripts/server/common.sh` loads generated `server-config.sh`
from the shared policy and provides receiver/locking helpers. Candidate schema cleanup lives in
`sql/reset-candidate.sql` and is reused by preparation and post-sync cleanup;
it refuses to run outside `workouts_restore_candidate`.

The job images install Python 3 in addition to OpenSSH. Push and web pipelines
on `main` run the restore and test synchronization automatically.

The parent pipeline validates the repository and inputs, then starts the
`refresh_test_database` child pipeline. The five logical phases remain:

| Stage | Jobs in execution order |
| --- | --- |
| `validate` (parent) | Repository checks and PostgreSQL integration in parallel, then preflight |
| `setup` (child) | Ansible bootstrap |
| `backup` (child) | Production backup verification → test backup → SSH transport verification |
| `sync` (child) | Candidate preparation → automatic production restore → test sync |
| `verify` (child) | Independent post-sync verification |

Same-stage `needs` dependencies preserve this order and keep test sync blocked
until the production restore succeeds.

Preflight validates the 11 configured CI/CD variables before bootstrap changes
the test server. See [configuration](docs/CONFIGURATION.md) for the variable
names and File types, and [Ansible setup](ansible/README.md) for prerequisites.
The root `.gitlab-ci.yml` owns validation and the exclusive trigger;
`ci/sync.yml` contains the server jobs. Open the child pipeline from the
`refresh_test_database` job to follow progress. No manual job start is required.

The trigger holds `workouts-refresh-pipeline` until the child finishes.
Other pipelines can validate
concurrently but wait before starting server operations. The child deliberately
does not request the parent's resource, avoiding a parent/child deadlock.
`strategy: depend` retains compatibility with installations before GitLab 18.2.
Candidate preparation, restoration and test synchronization also share a
server-side lock against simultaneous commands.

`sync-test.sh` separates schema validation, backup, export, atomic transfer,
verification and candidate cleanup into functions. Queries live under `sql/`;
bootstrap installs these reviewed assets root-owned and read-only. The bootstrap
playbook imports prerequisite, receiver, PostgreSQL and installation checks from
`ansible/tasks/bootstrap/`.

Run offline validation with `bash scripts/tests/static-checks.sh` after installing
`PyYAML==6.0.2`. Pipeline/Ansible invariants live in `tests/test_pipeline.py`,
and mocked server failure/recovery checks in `tests/test_server_sync.py`.
The PostgreSQL integration test runs separately against the
disposable PostgreSQL 17 service in CI.

The transfer set is explicitly reviewed in `sql/expected-business-tables.sql`.
Schema validation compares exact table names (including registration and bug-report
tables), then target table presence and column definitions before stopping the API.
When migrations add or remove business tables, review and update this manifest;
unknown tables stop synchronization rather than being silently included.

The shared policy now also drives the backup role, local PostgreSQL port, receiver
size limit and server paths. Sync verifies every copied table's content, clears
registration/password-reset outgoing mail and sessions, and waits for Docker API
health. See [configuration and recovery](docs/CONFIGURATION.md) for backup-role
maintenance and the root-only, snapshot-first candidate reset command.
