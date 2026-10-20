#!/usr/bin/env bash
set -Eeuo pipefail

# This program is called ONLY via authorized_keys force-command.
# Keep existing verification workflow unchanged when no command is requested.
case "${SSH_ORIGINAL_COMMAND:-}" in
  '') exec /usr/local/libexec/workouts-db-sync/receive-backup.sh ;;
  'prepare-candidate') exec sudo -n /usr/local/libexec/workouts-db-sync/prepare-candidate.sh ;;
  'sync-test') exec sudo -n /usr/local/libexec/workouts-db-sync/sync-test.sh ;;
  'restore-candidate') exec /usr/local/libexec/workouts-db-sync/receive-restore-candidate.sh ;;
  *) echo 'ERROR: SSH command is not permitted' >&2; exit 1 ;;
esac
