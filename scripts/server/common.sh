#!/usr/bin/env bash
# Sourced only from the root-owned installation, never from the SSH environment.
set -Eeuo pipefail
umask 077

readonly BASE='/usr/local/libexec/workouts-db-sync'
readonly PG='/usr/lib/postgresql/17/bin'
readonly CANDIDATE='workouts_restore_candidate'
readonly TEST_DB='workouts_test'
readonly INCOMING='/home/workouts-db-restore/incoming'
readonly LOCK='/run/lock/workouts-db-sync-test.lock'

fail() { echo "ERROR: $*" >&2; exit 1; }
require_root() { [[ "$(id -u)" == 0 ]] || fail 'root required'; }
require_receiver() { [[ "$(id -un)" == 'workouts-db-restore' ]] || fail 'Incorrect OS user'; }
lock_candidate() {
  # Linux flock accepts exclusive locking on a read-only descriptor.
  exec 9<"$LOCK"
  flock -n 9 || fail 'Candidate maintenance, restore or test sync already running'
}
pg() { runuser -u postgres -- "$@"; }
q() { pg "$PG/psql" -XAtq -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
loader_query() {
  "$PG/psql" -XAtq -v ON_ERROR_STOP=1 -h /var/run/postgresql -p 5432 \
    -U workouts_restore_loader -d "$CANDIDATE" -c "$1"
}
receive_archive() {
  local path="$1"
  head -c 104857601 > "$path"
  [[ -s "$path" ]] || fail 'Empty dump'
  [[ "$(stat -c %s "$path")" -le 104857600 ]] || fail 'Dump exceeds 100 MiB'
  [[ "$(head -c 5 "$path")" == PGDMP ]] || fail 'Not a custom PostgreSQL dump'
  "$PG/pg_restore" --list "$path" >/dev/null
}
