#!/usr/bin/env bash
# Shared GitLab File-variable handling. Source only from Bash with strict mode.
ssh_workspace() {
  umask 077
  SSH_WORKDIR="$(mktemp -d)"
  trap 'rm -rf -- "$SSH_WORKDIR"' EXIT
}

ssh_file() {
  local source_path="$1" dest_name="$2"
  [[ -f "$source_path" && -s "$source_path" ]] || {
    printf 'ERROR: missing/empty SSH file variable: %s\n' "$dest_name" >&2
    return 1
  }
  install -m 600 -- "$source_path" "$SSH_WORKDIR/$dest_name"
}

ssh_test_setup() {
  : "${TEST_HOST:?Missing TEST_HOST}"
  [[ "$TEST_HOST" == '192.168.1.37' ]] || { echo 'ERROR: Unexpected test host' >&2; return 1; }
  : "${TEST_RESTORE_SSH_KEY:?Missing TEST_RESTORE_SSH_KEY}"
  : "${TEST_RESTORE_SSH_KNOWN_HOSTS:?Missing TEST_RESTORE_SSH_KNOWN_HOSTS}"
  ssh_file "$TEST_RESTORE_SSH_KEY" test_key
  ssh_file "$TEST_RESTORE_SSH_KNOWN_HOSTS" test_known_hosts
}

ssh_prod_setup() {
  : "${PROD_HOST:?Missing PROD_HOST}"
  : "${PROD_BACKUP_SSH_KEY:?Missing PROD_BACKUP_SSH_KEY}"
  : "${PROD_SSH_KNOWN_HOSTS:?Missing PROD_SSH_KNOWN_HOSTS}"
  ssh_file "$PROD_BACKUP_SSH_KEY" prod_key
  ssh_file "$PROD_SSH_KNOWN_HOSTS" prod_known_hosts
}

ssh_prod_dump() {
  ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$SSH_WORKDIR/prod_known_hosts" \
    -i "$SSH_WORKDIR/prod_key" "workouts-db-backup@$PROD_HOST"
}

ssh_test_receiver() {
  ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$SSH_WORKDIR/test_known_hosts" \
    -i "$SSH_WORKDIR/test_key" "workouts-db-restore@$TEST_HOST" "$@"
}
