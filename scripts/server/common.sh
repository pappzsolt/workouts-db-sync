#!/usr/bin/env bash
# Sourced only from the root-owned installation, never from the SSH environment.
set -Eeuo pipefail
umask 077

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/server-config.sh"

fail() { echo "ERROR: $*" >&2; exit 1; }
require_root() { [[ "$(id -u)" == 0 ]] || fail 'root required'; }
require_receiver() { [[ "$(id -un)" == "$RECEIVER_USER" ]] || fail 'Incorrect OS user'; }
lock_candidate() {
  # Linux flock accepts exclusive locking on a read-only descriptor.
  exec 9<"$LOCK"
  flock -n 9 || fail 'Candidate maintenance, restore or test sync already running'
}
pg() { runuser -u "$PG_ADMIN_USER" -- "$@"; }
q() { pg "$PG/psql" -XAtq -v ON_ERROR_STOP=1 -h "$PG_SOCKET" -p "$PG_PORT" -d "$1" -c "$2"; }
q_file() { pg "$PG/psql" -XAtq -v ON_ERROR_STOP=1 -h "$PG_SOCKET" -p "$PG_PORT" -d "$1" -f "$BASE/sql/$2"; }
loader_query() {
  "$PG/psql" -XAtq -v ON_ERROR_STOP=1 -h "$PG_SOCKET" -p "$PG_PORT" \
    -U "$LOADER_ROLE" -d "$CANDIDATE" -c "$1"
}
loader_file() {
  "$PG/psql" -XAtq -v ON_ERROR_STOP=1 -h "$PG_SOCKET" -p "$PG_PORT" \
    -U "$LOADER_ROLE" -d "$CANDIDATE" -f "$BASE/sql/$1"
}
receive_archive() {
  local path="$1"
  head -c "$((MAX_DUMP_BYTES + 1))" > "$path"
  [[ -s "$path" ]] || fail 'Empty dump'
  [[ "$(stat -c %s "$path")" -le "$MAX_DUMP_BYTES" ]] || fail "Dump exceeds configured limit: $MAX_DUMP_BYTES bytes"
  [[ "$(head -c 5 "$path")" == PGDMP ]] || fail 'Not a custom PostgreSQL dump'
  "$PG/pg_restore" --list "$path" >/dev/null
}
