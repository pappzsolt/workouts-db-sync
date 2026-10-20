#!/usr/bin/env bash
set -Eeuo pipefail
# File variables point to files in the GitLab runner container.
: "${ANSIBLE_BOOTSTRAP_SSH_KEY:?GitLab File variable required}"
: "${ANSIBLE_BOOTSTRAP_KNOWN_HOSTS:?GitLab File variable required}"
: "${TEST_RESTORE_SSH_KEY:?GitLab File variable required}"
: "${TEST_RESTORE_SSH_KNOWN_HOSTS:?GitLab File variable required}"
: "${ANSIBLE_BECOME_PASSWORD:?GitLab masked variable required (sudo password)}"
for f in "$ANSIBLE_BOOTSTRAP_SSH_KEY" "$ANSIBLE_BOOTSTRAP_KNOWN_HOSTS" "$TEST_RESTORE_SSH_KEY" "$TEST_RESTORE_SSH_KNOWN_HOSTS"; do
  [[ -s "$f" ]] || { echo 'ERROR: SSH variable file is empty' >&2; exit 1; }
done
umask 077
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
install -m 600 "$ANSIBLE_BOOTSTRAP_SSH_KEY" "$DIR/admin.key"
install -m 600 "$ANSIBLE_BOOTSTRAP_KNOWN_HOSTS" "$DIR/admin.known_hosts"
install -m 600 "$TEST_RESTORE_SSH_KEY" "$DIR/restore.key"
ssh-keygen -y -f "$DIR/restore.key" > "$DIR/restore.pub"
# The public key is injected by environment variable only; private material
# stays in the protected temp dir and never enters repository or logs.
export WORKOUTS_RESTORE_PUBKEY="$(cat "$DIR/restore.pub")"
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_PRIVATE_KEY_FILE="$DIR/admin.key"
export ANSIBLE_SSH_COMMON_ARGS="-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$DIR/admin.known_hosts"
export ANSIBLE_BECOME_PASSWORD
ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
