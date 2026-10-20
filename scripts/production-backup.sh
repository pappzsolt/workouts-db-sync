#!/bin/sh
# Executed by the forced-command SSH key, as workouts-db-backup.
set -eu
umask 077
export PGPASSFILE=/home/workouts-db-backup/.pgpass
export PGCONNECT_TIMEOUT=10
# Reject any SSH-supplied command instead of interpreting it.
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
  echo 'Remote commands are not permitted' >&2
  exit 64
fi
exec /usr/lib/postgresql/17/bin/pg_dump \
  --host=127.0.0.1 --port=5432 --username=workouts_backup \
  --dbname=workouts --format=custom --no-owner --no-acl --no-password
