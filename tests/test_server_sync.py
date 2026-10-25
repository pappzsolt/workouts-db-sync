"""Exercise sync failure handling with fake Docker/PostgreSQL commands only."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ServerSyncTests(unittest.TestCase):
    def run_sync_step(self, step, failure="", source_tables=None):
        with tempfile.TemporaryDirectory() as directory:
            workdir = Path(directory)
            # Replace only the fixed installation import; all tested functions
            # come from the actual sync script. No server commands are executed.
            common = workdir / "common.sh"
            common.write_text("""set -Eeuo pipefail
BASE="$REPO_ROOT"
PG=/fixture/postgresql
CANDIDATE=workouts_restore_candidate
TEST_DB=workouts_test
PG_PORT=5432
PG_SOCKET=/fixture/socket
PG_ADMIN_USER=postgres
API=workouts-api
fail() { echo "$*" >&2; exit 1; }
chown() { :; }
docker() {
  echo "docker $*" >> "$TRACE"
  [[ "$*" != "$FAILURE" ]]
}
pg() {
  echo "postgres $*" >> "$TRACE"
  [[ "$FAILURE" != postgres ]]
}
q() {
  [[ "$FAILURE" != query ]] || return 9
  [[ "$FAILURE" != missing-test-table ]] || { echo 0; return; }
  echo 1
}
q_file() {
  [[ "$FAILURE" != fingerprint ]] || return 9
  case "$2" in
    business-tables.sql) printf '%s\n' "$SOURCE_TABLES" ;;
    expected-business-tables.sql) printf '%s\n' "$EXPECTED_TABLES" ;;
    table-columns.sql)
      if [[ "$FAILURE" == columns && "$1" == workouts_test ]]; then echo different; else echo same; fi ;;
    table-fingerprints.sql)
      [[ "$FAILURE" != empty-fingerprints ]] || return 0
      if [[ "$FAILURE" == content && "$1" == workouts_test ]]; then
        echo 'bug_reports|1|changed'
      else
        echo 'bug_reports|1|original'
      fi ;;
    assert-cleared.sql) [[ "$FAILURE" != uncleared ]] ;;
    *) echo unchanged ;;
  esac
}
""")
            source = (ROOT / "scripts/server/sync-test.sh").read_text()
            source = source.replace(
                'source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"',
                'source "$FIXTURE_COMMON"',
            )
            script = workdir / "sync-test.sh"
            script.write_text(source)
            trace = workdir / "trace"
            trace.touch()
            dump = workdir / "transfer.sql"
            dump.write_text(
                "SELECT pg_catalog.set_config('search_path', '', false);\nSELECT 1;\n"
            )
            Path(str(dump)+'.detail-versions').write_text('SELECT 1;\n')
            env = dict(
                os.environ,
                REPO_ROOT=str(ROOT),
                FIXTURE_COMMON=str(common),
                TRACE=str(trace),
                FAILURE=failure,
                FIXTURE_DUMP=str(dump),
                EXPECTED_TABLES="\n".join(self.reviewed_tables()),
                SOURCE_TABLES="\n".join(self.reviewed_tables() if source_tables is None else source_tables),
            )
            command = (
                """source "$1"
SQLFILE="$FIXTURE_DUMP"
api_stopped=0
TABLES=(users)
CHANGELOG_BEFORE=unchanged
trap cleanup EXIT
"""
                + step
            )
            result = subprocess.run(
                ["bash", "-c", command, "sync-fixture", str(script)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            return result, trace.read_text(), dump.exists()

    @staticmethod
    def reviewed_tables():
        return re.findall(r"\('([a-z_]+)'\)", (ROOT / "sql/expected-business-tables.sql").read_text())

    def test_current_schema_is_accepted_with_registration_reports_and_personal_tables(self):
        result, trace, _ = self.run_sync_step("validate_schema")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("docker stop", trace)

    def test_personal_tables_are_reviewed_explicitly(self):
        self.assertTrue({'personal_program_owners', 'personal_workout_owners',
                         'personal_standalone_workouts', 'personal_workout_templates'}
                        .issubset(self.reviewed_tables()))

    def test_unreviewed_table_changes_fail_before_any_data_transfer(self):
        tables = self.reviewed_tables()
        for changed in ([], tables[:-1], sorted(tables + ["unexpected_table"]),
                        sorted(tables[:-1] + ["unexpected_table"])):
            with self.subTest(tables=changed):
                result, trace, _ = self.run_sync_step("validate_schema\napply_transfer", source_tables=changed)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Source tables differ", result.stderr)
                self.assertNotIn("docker stop", trace)
                self.assertNotIn("postgres", trace)

    def test_missing_target_table_or_changed_columns_prevent_transfer(self):
        for failure in ("missing-test-table", "columns"):
            with self.subTest(failure=failure):
                result, trace, _ = self.run_sync_step("validate_schema\napply_transfer", failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("docker stop", trace)
                self.assertNotIn("postgres", trace)

    def test_transaction_failure_restarts_api_and_preserves_candidate(self):
        result, trace, dump_exists = self.run_sync_step(
            "apply_transfer\nclear_candidate", "postgres"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docker stop", trace)
        self.assertIn("docker start workouts-api", trace)
        self.assertNotIn("reset-candidate.sql", trace)
        self.assertFalse(dump_exists)

    def test_uncertain_docker_stop_still_attempts_restart(self):
        result, trace, _ = self.run_sync_step(
            "apply_transfer", "stop --time 30 workouts-api"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docker start workouts-api", trace)
        self.assertNotIn("postgres", trace)

    def test_query_failure_prevents_candidate_cleanup(self):
        result, trace, _ = self.run_sync_step(
            "verify_transfer\nclear_candidate", "fingerprint"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reset-candidate.sql", trace)

    def test_successful_transaction_verifies_before_clearing_candidate(self):
        result, trace, dump_exists = self.run_sync_step(
            "apply_transfer\nverify_transfer\nclear_candidate"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reset-candidate.sql", trace)
        self.assertIn("docker start workouts-api", trace)
        self.assertFalse(dump_exists)

    def test_same_row_count_but_changed_content_preserves_candidate(self):
        result, trace, _ = self.run_sync_step("verify_transfer\nclear_candidate", "content")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contents differ", result.stderr)
        self.assertIn("--- candidate", result.stderr)
        self.assertIn("+++ test", result.stderr)
        self.assertIn("-bug_reports|1|original", result.stderr)
        self.assertIn("+bug_reports|1|changed", result.stderr)
        self.assertNotIn("reset-candidate.sql", trace)

    def test_uncleared_mail_or_session_rows_preserve_candidate(self):
        result, trace, _ = self.run_sync_step("verify_transfer\nclear_candidate", "uncleared")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reset-candidate.sql", trace)

    def test_empty_fingerprint_output_cannot_appear_successful(self):
        result,trace,_=self.run_sync_step("verify_transfer\nclear_candidate","empty-fingerprints")
        self.assertNotEqual(result.returncode,0)
        self.assertIn("Missing table fingerprints",result.stderr)
        self.assertNotIn("reset-candidate.sql",trace)


class RecoveryTests(unittest.TestCase):
    def run_recovery(self, failure='', argument='--discard-candidate'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'common.sh').write_text('''set -Eeuo pipefail
BASE="$FIXTURE_ROOT"
PG=/fixture
PG_PORT=5432
PG_SOCKET=/fixture/socket
PG_ADMIN_USER=postgres
CANDIDATE=custom_candidate
BACKUP_DIR="$FIXTURE_ROOT"
fail() { echo "$*" >&2; exit 1; }
require_root() { :; }
lock_candidate() { echo locked >> "$TRACE"; }
install() { :; }
chown() { :; }
pg() { echo "$*" >> "$TRACE"; [[ "$*" != *"$FAILURE"* || -z "$FAILURE" ]]; }
''')
            (root/'reset-candidate.sh').write_text((ROOT/'scripts/server/reset-candidate.sh').read_text())
            trace=root/'trace'; trace.touch()
            result=subprocess.run(['bash',str(root/'reset-candidate.sh'),argument],env=dict(os.environ,FIXTURE_ROOT=str(root),TRACE=str(trace),FAILURE=failure),capture_output=True,text=True)
            return result,trace.read_text()

    def test_candidate_is_backed_up_and_archive_checked_before_reset(self):
        result,trace=self.run_recovery()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertLess(trace.index('pg_dump'),trace.index('pg_restore'))
        self.assertLess(trace.index('pg_restore'),trace.index('psql'))
        self.assertIn('candidate_db=custom_candidate',trace)
        self.assertIn('-d custom_candidate',trace)

    def test_failed_backup_or_archive_check_never_resets_candidate(self):
        for failure in ('pg_dump','pg_restore'):
            with self.subTest(failure=failure):
                result,trace=self.run_recovery(failure)
                self.assertNotEqual(result.returncode,0)
                self.assertNotIn('psql',trace)

    def test_recovery_requires_explicit_discard_argument(self):
        result,trace=self.run_recovery(argument='--unknown')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(trace,'')
