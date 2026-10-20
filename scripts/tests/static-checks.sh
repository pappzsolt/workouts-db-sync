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
print('Bash syntax and CI YAML validation OK')
PYTEST
