# Workouts DB Sync

GitLab CI/CD + Ansible orchestration for production-to-test PostgreSQL 17 data sync.

- **Production:** `hevsrv01` (`2.29.51.66`), `workouts`, read-only forced-command SSH backup.
- **Test:** `budsh` (`192.168.1.37`), `workouts_restore_candidate` → `workouts_test`.
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

The job images install Python 3 in addition to OpenSSH. A push on `main`
still requires manual approval at `restore_production_to_candidate`.
