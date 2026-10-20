#!/bin/sh
set -eu
: "${PROD_DEPLOY_SSH_KEY:?Set GitLab file-type PROD_DEPLOY_SSH_KEY}"
: "${PROD_SSH_KNOWN_HOSTS:?Set GitLab file-type PROD_SSH_KNOWN_HOSTS}"
: "${PROD_BACKUP_PUBLIC_KEY:?Set GitLab PROD_BACKUP_PUBLIC_KEY}"
: "${PROD_DEPLOY_USER:?Set GitLab PROD_DEPLOY_USER}"
: "${PROD_HOST:?Missing PROD_HOST}"
[ -s "$PROD_DEPLOY_SSH_KEY" ] && [ -s "$PROD_SSH_KNOWN_HOSTS" ]
case "$PROD_BACKUP_PUBLIC_KEY" in
  'ssh-ed25519 '* ) : ;;
  *) echo 'Invalid public key type' >&2; exit 1 ;;
esac
case "$PROD_DEPLOY_USER" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid deploy user' >&2; exit 1;; esac
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
chmod 700 "$workdir"
# Local payload; public key is data, never executed as shell.
cp scripts/production-backup.sh "$workdir/production-backup.sh"
printf '%s\n' "$PROD_BACKUP_PUBLIC_KEY" > "$workdir/backup.pub"
chmod 600 "$workdir/backup.pub"
# Remote sudo authorizations must cover only install of the fixed paths and
# the restricted authorized_keys update (see README). No general root login.
ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$PROD_SSH_KNOWN_HOSTS -i $PROD_DEPLOY_SSH_KEY"
# shellcheck disable=SC2086
scp $ssh_opts "$workdir/production-backup.sh" "$workdir/backup.pub" \
  "$PROD_DEPLOY_USER@$PROD_HOST:/tmp/" >&2
# Actual privileged installer must be separately provisioned on production;
# it verifies the files and installs with fixed destination paths.
# shellcheck disable=SC2086
ssh $ssh_opts "$PROD_DEPLOY_USER@$PROD_HOST" \
  'sudo -n /usr/local/sbin/workouts-db-backup-install' >&2
