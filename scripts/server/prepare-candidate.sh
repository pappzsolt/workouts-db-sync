#!/usr/bin/env bash
# Fixed-target maintenance action. Only runs via restricted SSH -> sudo.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_root
lock_candidate

# This operation is intentionally limited to the candidate database.
# Reject an unexpected populated candidate: never silently throw away a
# successfully restored backup after a failed test sync.
pg "$PG/psql" -X -q -v ON_ERROR_STOP=1 -1 -h "$PG_SOCKET" -p "$PG_PORT" -v candidate_db="$CANDIDATE" -d "$CANDIDATE" -f "$BASE/sql/prepare-candidate.sql"
echo 'Candidate prepared: no business tables, routines or sequences; dblink installed.'
