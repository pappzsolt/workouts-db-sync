# Central configuration

- `config/sync.yml`: canonical, non-secret DB names, roles, paths and expected topology policy; loaded by Ansible plays.
- GitLab **protected CI/CD variables**: `PROD_HOST`, `TEST_HOST`, `TEST_DB_HOST` (physical endpoints); also `TEST_DB_PORT` if not 5432.
- The GitLab variables `PROD_DB`, `TEST_DB`, `STAGING_DB` must match the policy in config/sync.yml. Do not duplicate IPs in a repository.
- `scripts/ansible_run.py` generates a private inventory from validated endpoint variables for each job. It does NOT attempt arbitrary Ansible execution on production; production's restricted SSH key remains forced-command only.
- The server-side privileged Bash scripts still have fixed database identifiers and paths; these are intentionally not accepted from untrusted SSH command arguments. They require a separate safely staged templating migration if made configurable.
- PostgreSQL 17, the test application container, and the production backup endpoint must already exist. Bootstrap configures the existing test side, not a fresh OS installation.
- This patch does not turn production PII into synthetic data; masking requires an explicit reviewed policy and dedicated test cases. Do not treat cleared login sessions as anonymization.
- `sql/reconcile-sequences.sql` is installed root-owned and read-only by the Ansible bootstrap playbook.
