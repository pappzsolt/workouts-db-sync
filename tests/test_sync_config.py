"""Fast, offline checks for the GitLab DB sync client."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('db_sync', ROOT / 'scripts/db_sync.py')
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)

class TestTargets(unittest.TestCase):
    def test_missing_production_host_fails_before_ssh(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict(os.environ, {'PROD_HOST': ''}):
                with self.assertRaisesRegex(ValueError, 'production host|production host|Unexpected'):
                    db.endpoint('production', Path(temp))

    def test_same_target_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict(os.environ, {'PROD_HOST':'host.example', 'TEST_HOST':'host.example'}):
                with self.assertRaises(ValueError):
                    db.endpoint('production', Path(temp))

    def test_sql_asset_exists_and_is_no_longer_in_shell(self):
        sql = (ROOT / 'sql/reconcile-sequences.sql').read_text()
        shell = (ROOT / 'scripts/server/sync-test.sh').read_text()
        self.assertIn('pg_catalog.setval', sql)
        self.assertIn('sql/reconcile-sequences.sql', shell)
        self.assertNotIn("cat <<'SEQSQL'", shell)

    def test_invalid_archive_header_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'bad.dump';p.write_bytes(b'WRONG')
            with self.assertRaises(ValueError): db.check_archive(p)

if __name__=='__main__': unittest.main()
