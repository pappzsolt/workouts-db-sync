#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_root
[[ "$#" == 1 && "$1" == --discard-candidate ]] || fail 'Usage: reset-candidate.sh --discard-candidate (backs up then empties candidate only)'
lock_candidate
install -d -o "$PG_ADMIN_USER" -g "$PG_ADMIN_USER" -m 700 "$BACKUP_DIR"
backup="$(mktemp "$BACKUP_DIR/candidate_before_reset.XXXXXXXX.dump")"
chown "$PG_ADMIN_USER:$PG_ADMIN_USER" "$backup"
pg "$PG/pg_dump" -h "$PG_SOCKET" -p "$PG_PORT" -Fc -d "$CANDIDATE" -f "$backup"
pg "$PG/pg_restore" --list "$backup" >/dev/null
pg "$PG/psql" -X -q -v ON_ERROR_STOP=1 -1 -h "$PG_SOCKET" -p "$PG_PORT" -v candidate_db="$CANDIDATE" -d "$CANDIDATE" -f "$BASE/sql/reset-candidate.sql"
echo "Candidate reset; recoverable snapshot retained: $backup"
