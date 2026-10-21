#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/libexec/workouts-db-sync/common.sh
require_receiver
lock_candidate

BACKUP="$(mktemp "$INCOMING/candidate.XXXXXXXX.dump")"
trap 'rm -f -- "$BACKUP"' EXIT

receive_archive "$BACKUP"

# Refuse a populated candidate. The preceding prepare_candidate job removes
# old orphaned routines/sequences, while preserving safety for failed syncs.
TABLES="$(loader_query "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f');")"
[[ "$TABLES" == 0 ]] || { echo 'ERROR: Candidate is not empty; refusing to overwrite' >&2; exit 1; }
# pg_restore also creates functions. A table-free database is not sufficient.
ROUTINES="$(loader_query "SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend dep WHERE dep.classid='pg_catalog.pg_proc'::regclass AND dep.objid=p.oid AND dep.deptype='e');")"
[[ "$ROUTINES" == 0 ]] || { echo 'ERROR: Candidate still has non-extension routines; refusing restore' >&2; exit 1; }

# No --create, no --clean, no superuser. Atomic rollback on restore error.
"$PG/pg_restore" -h /var/run/postgresql -p 5432 \
  -U workouts_restore_loader -d "$CANDIDATE" \
  --no-owner --no-acl --no-comments --single-transaction --exit-on-error "$BACKUP"

TABLES="$(loader_query "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public';")"
[[ "$TABLES" -gt 0 ]] || { echo 'ERROR: Restore produced no public tables' >&2; exit 1; }
echo "Candidate restore successful. Public tables: $TABLES"
