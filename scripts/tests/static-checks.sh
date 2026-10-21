#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find "$ROOT/scripts" -type f -name '*.sh' -print0)
python3 -m compileall -q "$ROOT/scripts" "$ROOT/tests"
python3 -m unittest discover -s "$ROOT/tests" -v
