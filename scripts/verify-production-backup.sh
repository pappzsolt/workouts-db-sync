#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/ssh.sh"
ssh_workspace
ssh_prod_setup
backup="$(mktemp)"
trap 'rm -f -- "$backup"; rm -rf -- "$SSH_WORKDIR"' EXIT
ssh_prod_dump > "$backup"
[[ -s "$backup" ]] || { echo 'ERROR: Empty production backup' >&2; exit 1; }
pg_restore --list "$backup" >/dev/null
echo "Production backup verified (archive: $(wc -c < "$backup") bytes)."
echo 'Backup not uploaded as artifact; retained only for the duration of this job.'
