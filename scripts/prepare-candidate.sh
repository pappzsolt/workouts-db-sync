#!/usr/bin/env bash
set -Eeuo pipefail
: "${TEST_RESTORE_SSH_KEY:?Missing TEST_RESTORE_SSH_KEY file variable}"
: "${TEST_RESTORE_SSH_KNOWN_HOSTS:?Missing TEST_RESTORE_SSH_KNOWN_HOSTS file variable}"
: "${TEST_HOST:?Missing TEST_HOST}"
[[ "$TEST_HOST" == '192.168.1.37' ]] || { echo 'ERROR: Unexpected test host' >&2; exit 1; }
umask 077
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
install -m 600 "$TEST_RESTORE_SSH_KEY" "$TEMP/id"
install -m 600 "$TEST_RESTORE_SSH_KNOWN_HOSTS" "$TEMP/known_hosts"
ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$TEMP/known_hosts" -i "$TEMP/id" \
  "workouts-db-restore@$TEST_HOST" prepare-candidate
