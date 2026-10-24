#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_receiver
lock_candidate

BACKUP="$(mktemp "$INCOMING/candidate.XXXXXXXX.dump")"
trap 'rm -f -- "$BACKUP"' EXIT

receive_archive "$BACKUP"

# Refuse a populated candidate. The preceding prepare_candidate job removes
# old orphaned routines/sequences, while preserving safety for failed syncs.
STATE="$(loader_file candidate-state.sql)"
[[ "$STATE" == '0|0|1' ]] || fail 'Candidate must be empty with only dblink installed; refusing restore'

# No --create, no --clean, no superuser. Atomic rollback on restore error.
"$PG/pg_restore" -h "$PG_SOCKET" -p "$PG_PORT" \
  -U "$LOADER_ROLE" -d "$CANDIDATE" \
  --no-owner --no-acl --no-comments --single-transaction --exit-on-error "$BACKUP"

TABLES="$(loader_query "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public';")"
[[ "$TABLES" -gt 0 ]] || { echo 'ERROR: Restore produced no public tables' >&2; exit 1; }
echo "Candidate restore successful. Public tables: $TABLES"
