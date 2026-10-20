#!/usr/bin/env bash
# Verification mode of the forced SSH receiver: no database writes.
set -Eeuo pipefail
umask 077
[[ "$(id -un)" == 'workouts-db-restore' ]] || exit 1
DIR='/home/workouts-db-restore/incoming'
BACKUP="$(mktemp "$DIR/verify.XXXXXXXX.dump")"
trap 'rm -f -- "$BACKUP"' EXIT
head -c 104857601 > "$BACKUP"
[[ -s "$BACKUP" && "$(stat -c %s "$BACKUP")" -le 104857600 ]] || exit 1
[[ "$(head -c 5 "$BACKUP")" == PGDMP ]] || exit 1
/usr/lib/postgresql/17/bin/pg_restore --list "$BACKUP" >/dev/null
echo 'Backup received and archive index verified.'
echo 'No database was modified.'
