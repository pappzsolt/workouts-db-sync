#!/usr/bin/env bash
set -Eeuo pipefail

: "${PROD_BACKUP_SSH_KEY:?Missing PROD_BACKUP_SSH_KEY file variable}"
: "${PROD_SSH_KNOWN_HOSTS:?Missing PROD_SSH_KNOWN_HOSTS file variable}"
: "${TEST_RESTORE_SSH_KEY:?Missing TEST_RESTORE_SSH_KEY file variable}"
: "${TEST_RESTORE_SSH_KNOWN_HOSTS:?Missing TEST_RESTORE_SSH_KNOWN_HOSTS file variable}"
: "${PROD_HOST:?Missing PROD_HOST}"
: "${TEST_HOST:?Missing TEST_HOST}"

for file in "$PROD_BACKUP_SSH_KEY" "$PROD_SSH_KNOWN_HOSTS" \
            "$TEST_RESTORE_SSH_KEY" "$TEST_RESTORE_SSH_KNOWN_HOSTS"; do
  if [[ ! -f "$file" || ! -s "$file" ]]; then
    echo "ERROR: Missing or empty SSH file variable" >&2
    exit 1
  fi
done

# GitLab file variables may be world-readable in the build workspace.
# Copy secrets to a private directory, without changing GitLab-managed files.
umask 077
ssh_dir="$(mktemp -d)"
trap 'rm -rf -- "$ssh_dir"' EXIT
install -m 600 "$PROD_BACKUP_SSH_KEY" "$ssh_dir/prod_key"
install -m 600 "$PROD_SSH_KNOWN_HOSTS" "$ssh_dir/prod_known_hosts"
install -m 600 "$TEST_RESTORE_SSH_KEY" "$ssh_dir/test_key"
install -m 600 "$TEST_RESTORE_SSH_KNOWN_HOSTS" "$ssh_dir/test_known_hosts"

# Production authorized_keys forces a read-only pg_dump command.
# Test authorized_keys forces receive-backup.sh, which validates then deletes the dump.
ssh -T -o BatchMode=yes -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$ssh_dir/prod_known_hosts" \
  -i "$ssh_dir/prod_key" \
  "workouts-db-backup@$PROD_HOST" \
  | ssh -T -o BatchMode=yes -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$ssh_dir/test_known_hosts" \
      -i "$ssh_dir/test_key" \
      "workouts-db-restore@$TEST_HOST"

echo "Production-to-test restricted SSH backup transfer verified. No database was modified."
