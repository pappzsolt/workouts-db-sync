"""Fast, offline checks for the GitLab DB sync client."""

import importlib.util
import os
import json
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

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
            self.assertEqual(kwargs["cwd"], ROOT)
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
    def test_interrupted_transfer_terminates_and_reaps_both_processes(self):
        source, target = MagicMock(), MagicMock()
        source.poll.return_value = target.poll.return_value = None
        target.wait.side_effect = [KeyboardInterrupt, 0]
        with (
            patch.object(db.subprocess, "Popen", side_effect=[source, target]),
            self.assertRaises(KeyboardInterrupt),
        ):
            db.forward_stream(["source"], ["target"])
        source.stdout.close.assert_called_once()
        for process in (source, target):
            process.terminate.assert_called_once()
            self.assertTrue(process.wait.called)

    def test_receiver_launch_failure_terminates_and_reaps_source(self):
        source = MagicMock()
        source.poll.return_value = None
        with (
            patch.object(
                db.subprocess, "Popen", side_effect=[source, OSError("launch failed")]
            ),
            self.assertRaisesRegex(OSError, "launch failed"),
        ):
            db.forward_stream(["source"], ["target"])
        source.stdout.close.assert_called_once()
        source.terminate.assert_called_once()
        source.wait.assert_called_once()

    def test_stream_transfer_propagates_a_source_failure(self):
        with self.assertRaisesRegex(RuntimeError, "production=9"):
            db.forward_stream(
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stdout.buffer.write(b'PGDMPfixture'); sys.exit(9)",
                ],
                [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
            )

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


class PolicyTests(unittest.TestCase):
    def test_policy_changes_are_consumed_by_the_backup_client(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {"TEST_DB_PASSWORD":"fixture", "TEST_DB_HOST":"test.example", "TEST_DB":"custom_test"}
            policy = dict(db.POLICY, sync_test_db="custom_test", sync_backup_role="custom_reader", sync_pg_port=6543)
            with patch.dict(os.environ, env, clear=True), patch.object(db, "POLICY", policy), patch.object(db, "check_archive"), patch.object(db.subprocess, "run") as run:
                (Path(directory)/'test.dump').write_bytes(b'PGDMPfixture')
                db.backup_test(Path(directory))
            connection = run.call_args.kwargs['env']
            self.assertEqual((connection['PGDATABASE'],connection['PGUSER'],connection['PGPORT']),('custom_test','custom_reader','6543'))

    def test_backup_rejects_database_or_port_override_before_connecting(self):
        env = {"TEST_DB_PASSWORD":"fixture", "TEST_DB_HOST":"test.example", "TEST_DB":db.POLICY['sync_test_db']}
        for override in ({'TEST_DB':'wrong'}, {'TEST_DB_PORT':'9999'}):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as directory:
                with patch.dict(os.environ, dict(env, **override), clear=True), patch.object(db.subprocess,'run') as run, self.assertRaises(ValueError):
                    db.backup_test(Path(directory))
                run.assert_not_called()

    def test_invalid_policy_rejects_unsafe_targets_and_limits(self):
        from policy import POLICY, load_policy
        for override in ({'sync_candidate_db':POLICY['sync_test_db']}, {'sync_backup_role':'reader; DROP DATABASE x'}, {'sync_max_dump_bytes':0}, {'sync_pg_port':True}):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)/'policy.json'
                path.write_text(json.dumps(dict(POLICY, **override)))
                with self.assertRaises(ValueError):
                    load_policy(path)

    def test_rendered_runtime_policy_uses_configuration_and_cannot_be_overridden_by_environment(self):
        # Use the same template file/filter semantics as Ansible, then execute Bash.
        import jinja2
        from policy import POLICY
        policy = dict(POLICY, sync_test_db='custom_test',sync_candidate_db='custom_candidate',sync_pg_port=6543,sync_max_dump_bytes=512)
        env = jinja2.Environment(undefined=jinja2.StrictUndefined)
        env.filters['quote'] = shlex.quote
        rendered = env.from_string((ROOT/'ansible/templates/server-config.sh.j2').read_text()).render(policy)
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)/'server-config.sh'
            config.write_text(rendered)
            common = Path(directory)/'common.sh'
            common.write_text((ROOT/'scripts/server/common.sh').read_text())
            result = subprocess.run(['bash','-c','source "$1"; printf "%s|%s|%s|%s" "$TEST_DB" "$CANDIDATE" "$PG_PORT" "$MAX_DUMP_BYTES"','test',str(common)],env=dict(os.environ,TEST_DB='wrong',PG_PORT='9999'),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,'custom_test|custom_candidate|6543|512')

    def test_receiver_uses_configured_limit_including_boundary_and_invalid_header(self):
        import jinja2
        from policy import POLICY
        environment=jinja2.Environment(undefined=jinja2.StrictUndefined)
        environment.filters['quote']=shlex.quote
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            policy=dict(POLICY,sync_max_dump_bytes=8,sync_pg_bin=str(root))
            (root/'server-config.sh').write_text(environment.from_string((ROOT/'ansible/templates/server-config.sh.j2').read_text()).render(policy))
            (root/'common.sh').write_text((ROOT/'scripts/server/common.sh').read_text())
            restore=root/'pg_restore'; restore.write_text('#!/bin/sh\nexit 0\n'); restore.chmod(0o755)
            # Portable stat fixture: only adapt Linux stat syntax for macOS execution.
            command='source "$1"; stat() { wc -c < "$3"; }; receive_archive "$2"'
            for data,expected in [(b'PGDMP123',0),(b'PGDMP1234',1),(b'WRONG123',1),(b'',1)]:
                with self.subTest(data=data):
                    result=subprocess.run(['bash','-c',command,'receiver',str(root/'common.sh'),str(root/'received.dump')],input=data,capture_output=True)
                    self.assertEqual(result.returncode,expected,result.stderr)
