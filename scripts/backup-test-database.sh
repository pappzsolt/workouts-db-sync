#!/bin/sh
set -eu

: "${TEST_DB_PASSWORD:?Set GitLab masked TEST_DB_PASSWORD variable}"

# The runner uses the default Docker bridge; this is the host gateway on budsh.
export PGHOST=172.17.0.1
export PGPORT=5432
export PGUSER=workouts_db_sync
export PGDATABASE=workouts_test
export PGPASSWORD="$TEST_DB_PASSWORD"
export PGCONNECT_TIMEOUT=10

umask 077
backup=$(mktemp)
trap 'rm -f "$backup"' EXIT
trap 'exit 1' HUP INT TERM

pg_dump --format=custom --no-owner --no-acl --no-password --file="$backup"
test -s "$backup" || { echo 'Empty test database backup' >&2; exit 1; }
pg_restore --list "$backup" > /dev/null

printf 'Test backup verified (archive: %s bytes).\n' "$(wc -c < "$backup")"
echo 'Backup not uploaded as artifact; retained only for the duration of this job.'
