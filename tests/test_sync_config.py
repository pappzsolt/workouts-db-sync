"""Fast, offline checks for the GitLab DB sync client."""

import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ci

spec = importlib.util.spec_from_file_location("db_sync", ROOT / "scripts/db_sync.py")
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
launcher_spec = importlib.util.spec_from_file_location(
    "ansible_run", ROOT / "scripts/ansible_run.py"
)
launcher = importlib.util.module_from_spec(launcher_spec)
launcher_spec.loader.exec_module(launcher)


class TestCiVariables(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.file = Path(self.temp.name) / "gitlab-file"
        self.file.write_text("fixture content")
        self.env = {key: "fixture value" for key in ci.CI_VALUE_VARIABLES}
        self.env.update({key: str(self.file) for key in ci.CI_FILE_VARIABLES})

    def test_all_eleven_gitlab_variables_are_accepted(self):
        with patch.dict(os.environ, self.env, clear=True):
            ci.validate_ci_variables()

    def test_each_missing_variable_is_reported_by_name_only(self):
        for key in self.env:
            with self.subTest(key=key):
                env = self.env.copy()
                del env[key]
                with (
                    patch.dict(os.environ, env, clear=True),
                    self.assertRaises(ValueError) as error,
                ):
                    ci.validate_ci_variables()
                self.assertIn(key, str(error.exception))
                self.assertNotIn("fixture", str(error.exception))

    def test_file_variables_reject_missing_empty_files_and_directories(self):
        empty = Path(self.temp.name) / "empty"
        empty.touch()
        for invalid in (empty, Path(self.temp.name), empty.with_name("missing")):
            with self.subTest(path=invalid):
                env = dict(self.env, PROD_BACKUP_SSH_KEY=str(invalid))
                with (
                    patch.dict(os.environ, env, clear=True),
                    self.assertRaisesRegex(ValueError, "PROD_BACKUP_SSH_KEY"),
                ):
                    ci.validate_ci_variables()

    def test_invalid_preflight_never_launches_ansible(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            patch("sys.argv", ["ansible_run.py", "preflight"]),
            patch.object(launcher.subprocess, "run") as run,
            patch("sys.stderr"),
        ):
            self.assertEqual(launcher.main(), 1)
        run.assert_not_called()

    def test_credentials_are_copied_privately_without_changing_original(self):
        self.file.chmod(0o644)
        with patch.dict(os.environ, self.env, clear=True):
            copied = ci.secret_file(
                "PROD_BACKUP_SSH_KEY", Path(self.temp.name), "private.key"
            )
        self.assertEqual(copied.read_bytes(), self.file.read_bytes())
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.file.stat().st_mode), 0o644)

    def test_preflight_uses_temporary_inventory_without_copying_credentials(self):
        env = dict(self.env, PROD_HOST="production.example", TEST_HOST="test.example")
        inventories = []

        def run(command, **kwargs):
            import json

            path = Path(command[command.index("-i") + 1])
            inventories.append(path)
            groups = json.loads(path.read_text())["all"]["children"]
            self.assertEqual(
                groups["workouts_production"]["hosts"]["production"]["ansible_host"],
                "production.example",
            )
            self.assertEqual(
                groups["workouts_test"]["hosts"]["test"]["ansible_host"], "test.example"
            )
            self.assertEqual(list(path.parent.iterdir()), [path])
            self.assertEqual(command[-1], "ansible/preflight.yml")
            return SimpleNamespace(returncode=0)

        with (
            patch.dict(os.environ, env, clear=True),
            patch("sys.argv", ["ansible_run.py", "preflight"]),
            patch.object(launcher.subprocess, "run", side_effect=run),
        ):
            self.assertEqual(launcher.main(), 0)
        self.assertFalse(inventories[0].exists())

    def test_each_ssh_endpoint_uses_its_own_restricted_identity(self):
        env = dict(self.env, PROD_HOST="production.example", TEST_HOST="test.example")
        for which, identity in (
            ("production", "workouts-db-backup@production.example"),
            ("test", "workouts-db-restore@test.example"),
        ):
            with self.subTest(which=which), patch.dict(os.environ, env, clear=True):
                command = db.endpoint(which, Path(self.temp.name))
                self.assertEqual(command[-1], identity)
                self.assertIn("StrictHostKeyChecking=yes", command)
                self.assertIn("IdentitiesOnly=yes", command)
                self.assertNotIn(self.file.read_text(), command)


class TestTargets(unittest.TestCase):
    def test_stream_transfer_delivers_the_archive_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "received.dump"
            db.forward_stream(
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stdout.buffer.write(b'PGDMPfixture')",
                ],
                [
                    sys.executable,
                    "-c",
                    "import pathlib, sys; pathlib.Path(sys.argv[1]).write_bytes(sys.stdin.buffer.read())",
                    str(target),
                ],
            )
            self.assertEqual(target.read_bytes(), b"PGDMPfixture")

    def test_stream_transfer_propagates_a_receiver_failure(self):
        with self.assertRaisesRegex(RuntimeError, "test=7"):
            db.forward_stream(
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stdout.buffer.write(b'PGDMPfixture')",
                ],
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stdin.buffer.read(); sys.exit(7)",
                ],
            )

    def test_missing_production_host_fails_before_ssh(self):
        with (
            tempfile.TemporaryDirectory() as temp,
            patch.dict(os.environ, {"PROD_HOST": ""}),
            self.assertRaisesRegex(ValueError, "PROD_HOST"),
        ):
            db.endpoint("production", Path(temp))

    def test_same_target_rejected(self):
        with (
            tempfile.TemporaryDirectory() as temp,
            patch.dict(
                os.environ, {"PROD_HOST": "host.example", "TEST_HOST": "host.example"}
            ),
            self.assertRaises(ValueError),
        ):
            db.endpoint("production", Path(temp))

    def test_sql_asset_exists_and_is_no_longer_in_shell(self):
        sql = (ROOT / "sql/reconcile-sequences.sql").read_text()
        shell = (ROOT / "scripts/server/sync-test.sh").read_text()
        self.assertIn("pg_catalog.setval", sql)
        self.assertIn("sql/reconcile-sequences.sql", shell)
        self.assertNotIn("cat <<'SEQSQL'", shell)

    def test_invalid_archive_header_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "bad.dump"
            p.write_bytes(b"WRONG")
            with self.assertRaises(ValueError):
                db.check_archive(p)


if __name__ == "__main__":
    unittest.main()
