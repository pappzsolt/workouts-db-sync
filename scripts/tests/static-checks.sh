#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find "$ROOT/scripts" -type f -name '*.sh' -print0)
python3 - "$ROOT/.gitlab-ci.yml" <<'PYTEST'
import sys
try:
    import yaml
except ImportError:
    print('PyYAML missing: install pyyaml to validate GitLab CI syntax',file=sys.stderr)
    raise SystemExit(1)
with open(sys.argv[1]) as f:
    cfg=yaml.safe_load(f)
assert cfg['workflow']['rules'][0]['when']=='always'
assert cfg['restore_production_to_candidate']['rules'][0]['when']=='manual'
assert cfg['sync_candidate_to_test']['stage']=='sync_test'
assert cfg['verify_production_backup']['script']==['bash scripts/verify-production-backup.sh']
assert cfg['preflight']['script']==['ansible-playbook -i localhost, -c local ansible/preflight.yml']
assert cfg['verify_sync_result']['stage']=='verify_result'
for item in ('ansible/preflight.yml', 'ansible/verify-result.yml', 'ansible/bootstrap.yml'):
    with open(f'{sys.argv[1].rsplit("/",1)[0]}/{item}', encoding='utf-8') as source:
        yaml.safe_load(source)
bootstrap_path = f'{sys.argv[1].rsplit("/",1)[0]}/ansible/bootstrap.yml'
verify_path = f'{sys.argv[1].rsplit("/",1)[0]}/ansible/verify-result.yml'
with open(bootstrap_path, encoding='utf-8') as source:
    bootstrap = yaml.safe_load(source)[0]
with open(verify_path, encoding='utf-8') as source:
    verify = yaml.safe_load(source)[0]
bootstrap_tasks = {task['name']: task for task in bootstrap['tasks'] if 'name' in task}
assert 'Require every entrypoint to be a root-owned executable regular file' in bootstrap_tasks
assert 'Read current candidate database owner' in bootstrap_tasks
assert 'Set candidate owner only if needed' in bootstrap_tasks
assert bootstrap_tasks['Set candidate owner only if needed']['when']
verify_tasks = {task['name']: task for task in verify['tasks'] if 'name' in task}
assert 'Read candidate cleanup state in one database round trip' in verify_tasks
assert "candidate_state.stdout | trim == '0|0|1'" in verify_tasks['Fail pipeline if postconditions are not satisfied']['ansible.builtin.assert']['that']
print('Bash syntax, CI YAML and Ansible refactor invariants OK')
PYTEST
