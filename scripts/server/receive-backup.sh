#!/usr/bin/env bash
# Verification mode of the forced SSH receiver: no database writes.
set -Eeuo pipefail
source /usr/local/libexec/workouts-db-sync/common.sh
require_receiver
BACKUP="$(mktemp "$INCOMING/verify.XXXXXXXX.dump")"
trap 'rm -f -- "$BACKUP"' EXIT
receive_archive "$BACKUP"
echo 'Backup received and archive index verified.'
echo 'No database was modified.'
