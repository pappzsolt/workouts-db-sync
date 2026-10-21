# Workouts DB Sync

GitLab CI/CD + Ansible orchestration for production-to-test PostgreSQL 17 data sync.

- **Production:** `PROD_HOST` from GitLab CI/CD variables, `workouts`, read-only forced-command SSH backup.
- **Test:** `TEST_HOST` from GitLab CI/CD variables, `workouts_restore_candidate` → `workouts_test`.
- **Infrastructure:** Ansible provisions test receiver, restricted loader and candidate.
- **Safety:** Git push pipelines pause for manual approval before production data restore; web-started pipelines run automatically. Liquibase and test-specific tables are preserved. Test DB is backed up on `budsh` before sync.

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
`scripts/ci.py`. The root-owned `scripts/server/common.sh` holds fixed server
targets and shared receiver/locking helpers. Candidate schema cleanup lives in
`sql/reset-candidate.sql` and is reused by preparation and post-sync cleanup;
it refuses to run outside `workouts_restore_candidate`.

The job images install Python 3 in addition to OpenSSH. A push on `main`
still requires manual approval at `restore_production_to_candidate`.

Preflight validates the 11 configured CI/CD variables before bootstrap changes
the test server. See [configuration](docs/CONFIGURATION.md) for the variable
names and File types, and [Ansible setup](ansible/README.md) for prerequisites.
The root `.gitlab-ci.yml` is the only pipeline; the obsolete nested checkout and
manual receiver installer have been removed.

Candidate preparation, restoration and test synchronization use one server-side
lock. Run only one refresh pipeline at a time: job resource groups serialize
individual jobs, but do not reserve the entire sequence for one pipeline.

Run offline validation with `bash scripts/tests/static-checks.sh` after installing
`PyYAML==6.0.2`. The PostgreSQL integration test runs separately against the
disposable PostgreSQL 17 service in CI.
