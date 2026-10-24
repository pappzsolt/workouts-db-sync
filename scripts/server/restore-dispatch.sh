#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# This program is called ONLY via authorized_keys force-command.
# Keep existing verification workflow unchanged when no command is requested.
case "${SSH_ORIGINAL_COMMAND:-}" in
  '') exec "$BASE"/receive-backup.sh ;;
  'prepare-candidate') exec sudo -n "$BASE"/prepare-candidate.sh ;;
  'sync-test') exec sudo -n "$BASE"/sync-test.sh ;;
  'restore-candidate') exec "$BASE"/receive-restore-candidate.sh ;;
  *) echo 'ERROR: SSH command is not permitted' >&2; exit 1 ;;
esac
