#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" == 0 ]] || { echo 'ERROR: Run as root (sudo)' >&2; exit 1; }
BASE='/usr/local/libexec/workouts-db-sync'
AUTH='/home/workouts-db-restore/.ssh/authorized_keys'
PUB='/home/pappzs/.ssh/workouts_db_restore.pub'
[[ -f "$PUB" && -s "$AUTH" ]] || { echo 'ERROR: Missing public key or current authorized_keys' >&2; exit 1; }
[[ -f "$BASE/receive-backup.sh" ]] || { echo 'ERROR: Existing verify receiver missing' >&2; exit 1; }
[[ "$(wc -l < "$AUTH")" -eq 1 ]] || { echo 'ERROR: Expected exactly one SSH key' >&2; exit 1; }
KEY="$(cat "$PUB")"
if ! grep -Fq -- "$KEY" "$AUTH"; then
  echo 'ERROR: Current authorized_keys does not contain the expected key' >&2
  exit 1
fi

SCRIPTDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for script in restore-dispatch.sh receive-restore-candidate.sh sync-test.sh; do
  bash -n "$SCRIPTDIR/$script"
  install -o root -g root -m 755 "$SCRIPTDIR/$script" "$BASE/$script"
done

# Install narrow sudo permission ONLY for the root-controlled fixed sync command.
printf 'workouts-db-restore ALL=(root) NOPASSWD: %s/sync-test.sh\n' "$BASE" > /etc/sudoers.d/workouts-db-sync-test
chmod 440 /etc/sudoers.d/workouts-db-sync-test
visudo -cf /etc/sudoers.d/workouts-db-sync-test >/dev/null

# Replace only the one known key, keeping the forced-command restriction.
cp -a "$AUTH" "$AUTH.before-candidate-restore"
printf 'restrict,command="%s/restore-dispatch.sh" %s\n' "$BASE" "$KEY" > "$AUTH"
chown workouts-db-restore:workouts-db-restore "$AUTH"
chmod 600 "$AUTH"

echo 'Restricted SSH dispatcher installed. Existing verification mode retained.'
echo 'Restore mode is limited to workouts_restore_candidate.'
