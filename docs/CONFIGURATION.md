# Central configuration

- `config/sync.yml`: canonical, non-secret DB names, roles, paths and expected topology policy; loaded by Ansible plays.
- GitLab **protected CI/CD variables**: `PROD_HOST`, `TEST_HOST`, `TEST_DB_HOST` (physical endpoints); also `TEST_DB_PORT` if not 5432.
- The GitLab variables `PROD_DB`, `TEST_DB`, `STAGING_DB` must match the policy in config/sync.yml. Do not duplicate IPs in a repository.
- `PROD_DB`, `TEST_DB`, `STAGING_DB` already have defaults in `.gitlab-ci.yml`; no additional GitLab UI variables are required for these names.
- Preflight runs before bootstrap and validates the 11 required GitLab variables: the five values `ANSIBLE_BECOME_PASSWORD`, `PROD_HOST`, `TEST_HOST`, `TEST_DB_HOST`, `TEST_DB_PASSWORD`, and the six File variables `ANSIBLE_BOOTSTRAP_SSH_KEY`, `ANSIBLE_BOOTSTRAP_KNOWN_HOSTS`, `PROD_BACKUP_SSH_KEY`, `PROD_SSH_KNOWN_HOSTS`, `TEST_RESTORE_SSH_KEY`, `TEST_RESTORE_SSH_KNOWN_HOSTS`. File variables must point to existing, nonempty files. Validation errors report variable names only.
- `scripts/ansible_run.py` generates a private inventory from validated endpoint variables for each job. It does NOT attempt arbitrary Ansible execution on production; production's restricted SSH key remains forced-command only.
- The server-side privileged Bash scripts still have fixed database identifiers and paths; these are intentionally not accepted from untrusted SSH command arguments. They require a separate safely staged templating migration if made configurable.
- PostgreSQL 17, the test application container, and the production backup endpoint must already exist. Bootstrap configures the existing test side, not a fresh OS installation.
- This patch does not turn production PII into synthetic data; masking requires an explicit reviewed policy and dedicated test cases. Do not treat cleared login sessions as anonymization.
- `sql/reconcile-sequences.sql` is installed root-owned and read-only by the Ansible bootstrap playbook.
- `sql/reset-candidate.sql` is installed with the same ownership and permissions; preparation and successful sync invoke it within a transaction.
- `scripts/ci.py` is the shared CI input/SSH layer. `scripts/server/common.sh` is installed root-owned alongside the fixed-purpose server entrypoints; it does not read endpoint or database overrides from the SSH environment.
