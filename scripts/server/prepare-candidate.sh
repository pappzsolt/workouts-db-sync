#!/usr/bin/env bash
# Fixed-target maintenance action. Only runs via restricted SSH -> sudo.
set -Eeuo pipefail
source /usr/local/libexec/workouts-db-sync/common.sh
require_root
lock_candidate

# This operation is intentionally limited to the candidate database.
# Reject an unexpected populated candidate: never silently throw away a
# successfully restored backup after a failed test sync.
pg "$PG/psql" -X -q -v ON_ERROR_STOP=1 -1 -d "$CANDIDATE" -f "$BASE/sql/prepare-candidate.sql"
echo 'Candidate prepared: no business tables, routines or sequences; dblink installed.'
