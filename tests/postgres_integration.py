"""Isolated PostgreSQL 17 integration test (GitLab ephemeral service only)."""

import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def psql(sql=None, *, file=None, database=None, transaction=False):
    argv = ["psql", "-XAt", "-v", "ON_ERROR_STOP=1"]
    if transaction:
        argv += ["-1"]
    if database is not None:
        argv += ["-d", database]
    if sql is not None:
        argv += ["-c", sql]
    if file is not None:
        argv += ["-f", str(file)]
    return subprocess.run(
        argv, check=True, text=True, capture_output=True
    ).stdout.strip()


@unittest.skipUnless(
    os.environ.get("WORKOUTS_EPHEMERAL_PG") == "1",
    "Needs GitLab isolated PostgreSQL service",
)
class PgIntegration(unittest.TestCase):
    def test_candidate_reset_rejects_other_databases_and_preserves_dblink(self):
        # Wrong-target guard must fail before DROP SCHEMA can execute.
        psql("CREATE TABLE public.reset_guard_fixture (id integer)")
        with self.assertRaises(subprocess.CalledProcessError):
            psql(file=ROOT / "sql/reset-candidate.sql")
        self.assertEqual(
            psql("SELECT to_regclass('public.reset_guard_fixture')"),
            "reset_guard_fixture",
        )

        candidate = "workouts_restore_candidate"
        psql(f"CREATE DATABASE {candidate}")
        try:
            psql("CREATE TABLE public.old_data (id integer)", database=candidate)
            with self.assertRaises(subprocess.CalledProcessError):
                psql(
                    file=ROOT / "sql/prepare-candidate.sql",
                    database=candidate,
                    transaction=True,
                )
            self.assertEqual(
                psql("SELECT to_regclass('public.old_data')", database=candidate),
                "old_data",
            )
            psql(
                file=ROOT / "sql/reset-candidate.sql",
                database=candidate,
                transaction=True,
            )
            self.assertEqual(
                psql(
                    "SELECT count(*) FROM pg_extension WHERE extname='dblink'",
                    database=candidate,
                ),
                "1",
            )
            self.assertEqual(
                psql(
                    "SELECT count(*) FROM pg_tables WHERE schemaname='public'",
                    database=candidate,
                ),
                "0",
            )
            self.assertEqual(
                psql(file=ROOT / "sql/candidate-state.sql", database=candidate), "0|0|1"
            )
            psql(
                file=ROOT / "sql/prepare-candidate.sql",
                database=candidate,
                transaction=True,
            )
            psql(
                file=ROOT / "sql/reset-candidate.sql",
                database=candidate,
                transaction=True,
            )
        finally:
            psql(f"DROP DATABASE {candidate}")

    def test_sequence_reconciliation_and_transaction_rollback(self):
        psql(
            "CREATE TABLE public.workouts (id BIGSERIAL PRIMARY KEY, name text NOT NULL)"
        )
        psql("INSERT INTO public.workouts (id,name) VALUES (3,'a'),(17,'b')")
        psql("SELECT setval('public.workouts_id_seq',1,false)")
        psql(file=ROOT / "sql/reconcile-sequences.sql")
        self.assertEqual(psql("SELECT last_value FROM public.workouts_id_seq"), "17")
        self.assertEqual(psql("SELECT is_called FROM public.workouts_id_seq"), "t")
        result = subprocess.run(
            [
                "psql",
                "-XAt",
                "-v",
                "ON_ERROR_STOP=1",
                "-1",
                "-c",
                "INSERT INTO public.workouts(name) VALUES ('should_roll_back'); SELECT 1/0",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(psql("SELECT count(*) FROM public.workouts"), "2")


if __name__ == "__main__":
    unittest.main()
