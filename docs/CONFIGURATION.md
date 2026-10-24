# Central configuration

- `config/sync.yml`: canonical non-secret policy in JSON-compatible YAML, read by both Ansible and the stdlib-only Python clients. It defines database/role names, ports, filesystem paths, dump-size limit and healthcheck retry policy.
- GitLab **protected CI/CD variables**: `PROD_HOST`, `TEST_HOST`, `TEST_DB_HOST` (physical endpoints); `TEST_DB_PORT`, if supplied, must match `sync_pg_port` in the shared policy.
- The GitLab variables `PROD_DB`, `TEST_DB`, `STAGING_DB` must match the policy in config/sync.yml. Do not duplicate IPs in a repository.
- `PROD_DB`, `TEST_DB`, `STAGING_DB` already have defaults in `.gitlab-ci.yml`; no additional GitLab UI variables are required for these names.
- Preflight runs before bootstrap and validates the 11 required GitLab variables: the five values `ANSIBLE_BECOME_PASSWORD`, `PROD_HOST`, `TEST_HOST`, `TEST_DB_HOST`, `TEST_DB_PASSWORD`, and the six File variables `ANSIBLE_BOOTSTRAP_SSH_KEY`, `ANSIBLE_BOOTSTRAP_KNOWN_HOSTS`, `PROD_BACKUP_SSH_KEY`, `PROD_SSH_KNOWN_HOSTS`, `TEST_RESTORE_SSH_KEY`, `TEST_RESTORE_SSH_KNOWN_HOSTS`. File variables must point to existing, nonempty files. Validation errors report variable names only.
- `scripts/ansible_run.py` generates a private inventory from validated endpoint variables for each job. It does NOT attempt arbitrary Ansible execution on production; production's restricted SSH key remains forced-command only.
- Bootstrap renders `server-config.sh` from the shared policy, installs it root-owned with mode 0644 and validates Bash syntax. All restricted server entrypoints load this sibling configuration; SSH environment variables and command arguments cannot select arbitrary database targets.
- PostgreSQL 17, the test application container, and the production backup endpoint must already exist. Bootstrap configures the existing test side, not a fresh OS installation.
- This patch does not turn production PII into synthetic data; masking requires an explicit reviewed policy and dedicated test cases. Do not treat cleared login sessions as anonymization.
- `sql/reconcile-sequences.sql` is installed root-owned and read-only by the Ansible bootstrap playbook.
- `sql/reset-candidate.sql` is installed with the same ownership and permissions; preparation and successful sync invoke it within a transaction.
- `scripts/ci.py` is the shared CI input/SSH layer. `scripts/server/common.sh` is installed root-owned alongside the fixed-purpose server entrypoints; it does not read endpoint or database overrides from the SSH environment.
- `.gitlab-ci.yml` validates inputs and reserves `workouts-refresh-pipeline` while the `ci/sync.yml` child runs. The parent forwards database defaults and pipeline overrides; protected project CI/CD variables remain available to child jobs on the same protected branch.
- Candidate-state, table-structure, Liquibase fingerprint and authentication cleanup queries live under `sql/`. `prepare-candidate.sql` includes the common reset script only after rejecting existing business tables and unexpected schemas.

## Backup access

Bootstrap applies `sql/backup-permissions.sql` transactionally to the TEST database
for `sync_backup_role`. The role must already exist. Existing tables/sequences
receive SELECT, and default privileges are configured for the actual table-owner
roles so their future migrations remain readable. It grants no write privileges
and does not change role passwords. If a new migration owner is introduced,
rerun bootstrap to configure that owner's defaults.

Production remains outside automatic Ansible provisioning. Its separately
installed `scripts/production-backup.sh` is a fixed forced-command endpoint.
The same SQL can be applied once by a production administrator using
`psql -X -v ON_ERROR_STOP=1 -1 -d workouts -v backup_role=workouts_backup -f sql/backup-permissions.sql`.
Use the actual administrative connection for that host/container; no production
administrative SSH credential is requested by this pipeline.

## Copy and postconditions

All copied/rebuilt tables are compared by row count and a deterministic content
fingerprint, independent of row order. Empty business tables are valid. Cleared
security/mail tables are intentionally excluded from source/target equality;
`sql/cleared-tables.sql` is the shared policy for clearing and asserting emptiness,
including BOTH password-reset and registration email outboxes. Registration
requests remain available. Liquibase history and test-only `login_rate_limits`
are preserved. Fingerprints are checked while the test API remains stopped.
API verification waits for Docker running=true AND health=healthy, with retries
from the shared policy. The optional HTTP endpoint is an additional check.

## Recovering a populated candidate

A failed sync preserves the candidate. The normal pipeline never silently clears
it. To discard it for a fresh production restore, an administrator on the TEST
server runs (using `sync_server_base` if changed):

```bash
sudo /usr/local/libexec/workouts-db-sync/reset-candidate.sh --discard-candidate
```

The root-only tool takes the shared maintenance lock, creates a private custom
archive in `sync_backup_dir`, checks its archive index, then resets ONLY the
configured candidate in one transaction. Failed backup/index verification prevents
reset. It preserves dblink and retains the snapshot for recovery. This action is
not in the SSH forced-command or passwordless-sudo allowlist. Restart the failed
prepare job (or a full pipeline) after recovery; bootstrap must have installed the
new scripts first. Never reset the test or production database to fix a candidate.

`sync_max_dump_bytes` defaults to 104857600 bytes and is applied by receivers from
the installed policy. Increase it deliberately as archives grow; exceeding it
remains a hard error. The reviewed table manifest is still maintained explicitly
when application migrations add/remove tables.

## Mobile detail versions during bulk import

Production migration 029 increments `user_workouts.detail_version` when child
prescription rows are inserted. That is correct for runtime edits, but replaying
a snapshot must preserve the original counter. `export-detail-versions.sql`
exports source id/version updates under the same candidate maintenance lock.
The transfer applies these updates after all INSERTs in the same transaction,
then verifies the complete row including detail_version. No trigger or constraint
is disabled, and no column is excluded from the fingerprint. The regression test
uses frozen production migration 029 trigger definitions and checks that normal
prescription changes still increment the counter after restoration.
