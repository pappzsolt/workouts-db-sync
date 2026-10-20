#!/bin/sh
# Intentionally read-only: no SSH, SQL writes, or remote state changes.
set -eu

fail() { echo "ERROR: $*" >&2; exit 1; }
require() {
  eval 'value=${'"$1"'-}'
  [ -n "$value" ] || fail "Missing variable: $1"
}

for variable in CI_PROJECT_PATH CI_COMMIT_BRANCH PROD_HOST PROD_DB TEST_HOST TEST_DB STAGING_DB; do
  require "$variable"
done

[ "$CI_PROJECT_PATH" = "workouts/workouts-db-sync" ] || fail "Wrong GitLab project: $CI_PROJECT_PATH"
[ "$CI_COMMIT_BRANCH" = "main" ] || fail "Preflight must run on main (current: $CI_COMMIT_BRANCH)"
[ "$PROD_DB" = "workouts" ] || fail "Unexpected production database"
[ "$TEST_DB" = "workouts_test" ] || fail "Unexpected test database"
[ "$STAGING_DB" = "workouts_restore_staging" ] || fail "Unexpected staging database"
[ "$PROD_HOST" != "$TEST_HOST" ] || fail "Production and test hosts must differ"
[ "$PROD_DB" != "$TEST_DB" ] || fail "Production and test database names must differ"

printf '%s\n' \
  'Preflight OK (configuration only)' \
  "Project: $CI_PROJECT_PATH" \
  "Branch: $CI_COMMIT_BRANCH" \
  "Production: $PROD_HOST / $PROD_DB (READ-ONLY intended)" \
  "Test: $TEST_HOST / $TEST_DB" \
  "Staging: $STAGING_DB" \
  'No database connections, backups, restores, or container actions were attempted.'
