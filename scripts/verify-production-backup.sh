#!/bin/sh
set -eu
: "${PROD_BACKUP_SSH_KEY:?Set GitLab file-type PROD_BACKUP_SSH_KEY}"
: "${PROD_SSH_KNOWN_HOSTS:?Set GitLab file-type PROD_SSH_KNOWN_HOSTS}"
: "${PROD_HOST:?Missing PROD_HOST}"
[ -s "$PROD_BACKUP_SSH_KEY" ] && [ -s "$PROD_SSH_KNOWN_HOSTS" ]
umask 077
backup=$(mktemp)
trap 'rm -f "$backup"' EXIT HUP INT TERM
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$PROD_SSH_KNOWN_HOSTS" \
  -i "$PROD_BACKUP_SSH_KEY" \
  "workouts-db-backup@$PROD_HOST" > "$backup"
[ -s "$backup" ] || { echo 'Empty backup' >&2; exit 1; }
pg_restore --list "$backup" > /dev/null
echo "Production backup verified (archive: $(wc -c < "$backup") bytes)."
echo 'Backup not uploaded as artifact; retained only for the duration of this job.'
