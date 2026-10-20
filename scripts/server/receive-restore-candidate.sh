#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ "$(id -un)" == 'workouts-db-restore' ]] || { echo 'ERROR: Incorrect OS user' >&2; exit 1; }
INCOMING='/home/workouts-db-restore/incoming'
TARGET='workouts_restore_candidate'
PG='/usr/lib/postgresql/17/bin'

# Prevent concurrent restores, including simultaneous remote jobs.
exec 9>"$INCOMING/.candidate-restore.lock"
flock -n 9 || { echo 'ERROR: Candidate restore already running' >&2; exit 1; }

BACKUP="$(mktemp "$INCOMING/candidate.XXXXXXXX.dump")"
trap 'rm -f -- "$BACKUP"' EXIT

# The 100 MiB limit is deliberately one byte above the permitted size.
head -c 104857601 > "$BACKUP"
[[ -s "$BACKUP" ]] || { echo 'ERROR: Empty dump' >&2; exit 1; }
[[ "$(stat -c %s "$BACKUP")" -le 104857600 ]] || { echo 'ERROR: Dump exceeds 100 MiB' >&2; exit 1; }
[[ "$(head -c 5 "$BACKUP")" == PGDMP ]] || { echo 'ERROR: Not a custom PostgreSQL dump' >&2; exit 1; }
"$PG/pg_restore" --list "$BACKUP" > /dev/null

# Refuse a populated candidate. The preceding prepare_candidate job removes
# old orphaned routines/sequences, while preserving safety for failed syncs.
TABLES="$("$PG/psql" -X -q -A -t -v ON_ERROR_STOP=1 \
  -h /var/run/postgresql -p 5432 -U workouts_restore_loader -d "$TARGET" \
  -c "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f');")"
[[ "$TABLES" == 0 ]] || { echo 'ERROR: Candidate is not empty; refusing to overwrite' >&2; exit 1; }
# pg_restore also creates functions. A table-free database is not sufficient.
ROUTINES="$("$PG/psql" -X -q -A -t -v ON_ERROR_STOP=1 \
  -h /var/run/postgresql -p 5432 -U workouts_restore_loader -d "$TARGET" \
  -c "SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend dep WHERE dep.classid='pg_catalog.pg_proc'::regclass AND dep.objid=p.oid AND dep.deptype='e');")"
[[ "$ROUTINES" == 0 ]] || { echo 'ERROR: Candidate still has non-extension routines; refusing restore' >&2; exit 1; }

# No --create, no --clean, no superuser. Atomic rollback on restore error.
"$PG/pg_restore" -h /var/run/postgresql -p 5432 \
  -U workouts_restore_loader -d "$TARGET" \
  --no-owner --no-acl --no-comments --single-transaction --exit-on-error "$BACKUP"

TABLES="$("$PG/psql" -X -q -A -t -v ON_ERROR_STOP=1 \
  -h /var/run/postgresql -p 5432 -U workouts_restore_loader -d "$TARGET" \
  -c "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public';")"
[[ "$TABLES" -gt 0 ]] || { echo 'ERROR: Restore produced no public tables' >&2; exit 1; }
echo "Candidate restore successful. Public tables: $TABLES"
