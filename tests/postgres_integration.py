"""Isolated PostgreSQL 17 integration test (GitLab ephemeral service only)."""

import os
import json
import tempfile
import uuid
import re
import shlex
import shutil
from contextlib import contextmanager
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = json.loads((ROOT / "config/sync.yml").read_text())


def psql(sql=None, *, file=None, database=None, transaction=False, variables=None):
    argv = ["psql", "-XAtq", "-v", "ON_ERROR_STOP=1", "-v", "candidate_db=" + POLICY["sync_candidate_db"]]
    for name, value in (variables or {}).items():
        argv += ["-v", f"{name}={value}"]
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
    def setUp(self):
        self.previous_database = os.environ['PGDATABASE']
        self.test_database = 'sync_test_' + uuid.uuid4().hex
        psql(f'CREATE DATABASE {self.test_database}')
        os.environ['PGDATABASE'] = self.test_database

    def tearDown(self):
        os.environ['PGDATABASE'] = self.previous_database
        psql(f'DROP DATABASE {self.test_database} WITH (FORCE)')

    def test_candidate_reset_rejects_other_databases_and_preserves_dblink(self):
        # Wrong-target guard must fail before DROP SCHEMA can execute.
        psql("CREATE TABLE public.reset_guard_fixture (id integer)")
        with self.assertRaises(subprocess.CalledProcessError):
            psql(file=ROOT / "sql/reset-candidate.sql")
        self.assertEqual(
            psql("SELECT to_regclass('public.reset_guard_fixture')"),
            "reset_guard_fixture",
        )

        candidate = POLICY["sync_candidate_db"]
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

    @contextmanager
    def database(self):
        name = "sync_fixture_" + uuid.uuid4().hex
        psql(f'CREATE DATABASE "{name}"')
        try:
            yield name
        finally:
            psql(f'DROP DATABASE "{name}" WITH (FORCE)')

    def test_fingerprints_detect_changed_content_even_when_row_counts_match(self):
        with self.database() as db:
            psql("CREATE TABLE payload(id integer, value text); INSERT INTO payload VALUES (1,'before'),(2,NULL)", database=db)
            original = psql(file=ROOT / "sql/table-fingerprints.sql", database=db)
            psql("UPDATE payload SET value='after' WHERE id=1", database=db)
            changed = psql(file=ROOT / "sql/table-fingerprints.sql", database=db)
            self.assertNotEqual(original, changed)
            self.assertEqual(original.split('|')[1], changed.split('|')[1])
            psql("UPDATE payload SET value='before' WHERE id=1; CREATE TABLE reversed AS SELECT * FROM payload ORDER BY id DESC; TRUNCATE payload; INSERT INTO payload SELECT * FROM reversed; DROP TABLE reversed", database=db)
            self.assertEqual(original, psql(file=ROOT / "sql/table-fingerprints.sql", database=db))
            psql("INSERT INTO payload VALUES (1,'before')", database=db)
            self.assertNotEqual(original, psql(file=ROOT / "sql/table-fingerprints.sql", database=db))

    def test_registration_mail_and_sessions_are_cleared_but_requests_remain(self):
        with self.database() as db:
            names = ['auth_login_attempts','login_audit_logs','password_reset_tokens',
                     'password_reset_email_outbox','registration_email_outbox',
                     'refresh_token_revocations','refresh_token_families','account_token_versions']
            for name in names:
                psql(f"CREATE TABLE {name}(id bigint GENERATED BY DEFAULT AS IDENTITY, payload text); INSERT INTO {name}(payload) VALUES ('production')", database=db)
            psql("CREATE TABLE registration_requests(id bigint PRIMARY KEY, status text); INSERT INTO registration_requests VALUES(1,'PENDING')", database=db)
            before = psql(file=ROOT / "sql/table-fingerprints.sql", database=db)
            psql(file=ROOT / "sql/clear-test-auth.sql", database=db, transaction=True)
            psql(file=ROOT / "sql/assert-cleared.sql", database=db)
            for name in names:
                self.assertEqual(psql(f"SELECT count(*) FROM {name}",database=db), '0')
            self.assertEqual(before, psql(file=ROOT / "sql/table-fingerprints.sql", database=db))
            self.assertEqual(psql("SELECT status FROM registration_requests WHERE id=1",database=db),'PENDING')
            psql("INSERT INTO registration_email_outbox(payload) VALUES ('unexpected')",database=db)
            with self.assertRaises(subprocess.CalledProcessError):
                psql(file=ROOT / "sql/assert-cleared.sql",database=db)

    def test_backup_permissions_cover_existing_and_future_tables_without_write_access(self):
        owner, reader = 'owner_' + uuid.uuid4().hex, 'reader_' + uuid.uuid4().hex
        psql(f'CREATE ROLE {owner} NOLOGIN; CREATE ROLE {reader} NOLOGIN')
        try:
            with self.database() as db:
                psql(f"GRANT USAGE, CREATE ON SCHEMA public TO {owner}; SET ROLE {owner}; CREATE TABLE existing(id bigserial, value text); INSERT INTO existing(value) VALUES ('kept')",database=db)
                for _ in range(2):  # rerun must remain valid
                    psql(file=ROOT / 'sql/backup-permissions.sql',database=db,transaction=True,variables={'backup_role':reader})
                psql(f"SET ROLE {owner}; CREATE TABLE future(id bigserial, value text); INSERT INTO future(value) VALUES ('new')",database=db)
                self.assertEqual(psql(f'SET ROLE {reader}; SELECT value FROM existing; SELECT value FROM future; SELECT last_value FROM future_id_seq',database=db), 'kept\nnew\n1')
                with self.assertRaises(subprocess.CalledProcessError):
                    psql(f"SET ROLE {reader}; INSERT INTO existing(value) VALUES ('forbidden')",database=db)
                self.assertEqual(psql('SELECT count(*) FROM existing',database=db),'1')
        finally:
            psql(f'DROP ROLE {reader}; DROP ROLE {owner}')

    def test_candidate_snapshot_can_be_restored_after_explicit_reset(self):
        candidate = POLICY['sync_candidate_db']
        psql(f'CREATE DATABASE {candidate}')
        try:
            psql("CREATE TABLE retained(id integer, note text); INSERT INTO retained VALUES(1,'recoverable')",database=candidate)
            with tempfile.TemporaryDirectory() as directory:
                dump = str(Path(directory) / 'candidate.dump')
                subprocess.run(['pg_dump','-Fc','-d',candidate,'-f',dump],check=True,capture_output=True)
                subprocess.run(['pg_restore','--list',dump],check=True,capture_output=True)
                psql(file=ROOT / 'sql/reset-candidate.sql',database=candidate,transaction=True)
                self.assertEqual(psql(file=ROOT / 'sql/candidate-state.sql',database=candidate),'0|0|1')
                with self.database() as restored:
                    subprocess.run(['pg_restore','--no-owner','--no-acl','--single-transaction','--exit-on-error','-d',restored,dump],check=True,capture_output=True)
                    self.assertEqual(psql('SELECT note FROM retained WHERE id=1',database=restored),'recoverable')
        finally:
            psql(f'DROP DATABASE {candidate}')

    def test_real_dump_transfer_preserves_content_history_and_test_only_data(self):
        names = re.findall(r"\('([a-z_]+)'\)",(ROOT/'sql/expected-business-tables.sql').read_text())
        with self.database() as source, self.database() as target, tempfile.TemporaryDirectory() as directory:
            for db, prefix in ((source,'production'),(target,'stale')):
                psql("CREATE TABLE account_login_identifiers(identifier text PRIMARY KEY,user_id bigint,coach_id bigint)",database=db)
                for name in names:
                    if name != 'account_login_identifiers':
                        psql(f'CREATE TABLE {name}(id bigserial PRIMARY KEY,payload text)',database=db)
                psql('''CREATE FUNCTION rebuild_alias() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                  IF TG_TABLE_NAME='users' THEN INSERT INTO account_login_identifiers VALUES(NEW.payload,NEW.id,NULL);
                  ELSE INSERT INTO account_login_identifiers VALUES(NEW.payload,NULL,NEW.id); END IF;
                  RETURN NEW;
                END $$;
                CREATE TRIGGER user_alias AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION rebuild_alias();
                CREATE TRIGGER coach_alias AFTER INSERT ON coaches FOR EACH ROW EXECUTE FUNCTION rebuild_alias();''',database=db)
                for name in names:
                    if name != 'account_login_identifiers':
                        psql(f"INSERT INTO {name}(id,payload) VALUES(17,'{prefix}_{name}')",database=db)
                psql(f"CREATE TABLE databasechangelog(orderexecuted int,id text,author text); INSERT INTO databasechangelog VALUES(1,'{prefix}','fixture')",database=db)
            psql("CREATE TABLE login_rate_limits(id int,payload text); INSERT INTO login_rate_limits VALUES(1,'test-only')",database=target)
            work=Path(directory)
            common=work/'common.sh'
            common.write_text('set -Eeuo pipefail\n'+
                f'BASE={shlex.quote(str(ROOT))}\nPG={shlex.quote(str(Path(shutil.which("pg_dump")).parent))}\nPG_PORT={os.environ["PGPORT"]}\nPG_SOCKET={shlex.quote(os.environ["PGHOST"])}\nPG_ADMIN_USER=fixture\nCANDIDATE={source}\nTEST_DB={target}\nAPI=fixture-api\n'+'''
fail() { echo "$*" >&2; exit 1; }
chown() { :; }
docker() { echo "docker $*" >> "$TRACE"; }
pg() { "$@"; }
q() { psql -XAtq -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
q_file() { psql -XAtq -v ON_ERROR_STOP=1 -d "$1" -f "$BASE/sql/$2"; }
''')
            script=work/'sync-test.sh'
            script.write_text((ROOT/'scripts/server/sync-test.sh').read_text().replace(
                'source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"',
                f'source {shlex.quote(str(common))}'))
            command='source "$1"; SQLFILE="$2"; api_stopped=0; trap cleanup EXIT; validate_schema; export_candidate; apply_transfer; verify_transfer'
            result=subprocess.run(['bash','-c',command,'transfer',str(script),str(work/'transfer.sql')],env=dict(os.environ,TRACE=str(work/'trace')),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(psql('SELECT payload FROM bug_reports',database=target),'production_bug_reports')
            self.assertEqual(psql('SELECT count(*) FROM registration_email_outbox',database=target),'0')
            self.assertEqual(psql('SELECT count(*) FROM account_login_identifiers',database=target),'2')
            self.assertEqual(psql('SELECT payload FROM login_rate_limits',database=target),'test-only')
            self.assertEqual(psql('SELECT id FROM databasechangelog',database=target),'stale')
            self.assertEqual(psql("INSERT INTO bug_reports(payload) VALUES('next') RETURNING id",database=target),'18')
            self.assertIn('docker start fixture-api',(work/'trace').read_text())


if __name__ == "__main__":
    unittest.main()
