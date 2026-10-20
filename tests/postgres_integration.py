"""Isolated PostgreSQL 17 integration test (GitLab ephemeral service only)."""
import os
import subprocess
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]

def psql(sql=None, *, file=None):
    argv=['psql','-XAt','-v','ON_ERROR_STOP=1']
    if sql is not None: argv += ['-c',sql]
    if file is not None: argv += ['-f',str(file)]
    return subprocess.run(argv,check=True, text=True,capture_output=True).stdout.strip()

@unittest.skipUnless(os.environ.get('WORKOUTS_EPHEMERAL_PG')=='1','Needs GitLab isolated PostgreSQL service')
class PgIntegration(unittest.TestCase):
    def test_sequence_reconciliation_and_transaction_rollback(self):
        psql('CREATE TABLE public.workouts (id BIGSERIAL PRIMARY KEY, name text NOT NULL)')
        psql("INSERT INTO public.workouts (id,name) VALUES (3,'a'),(17,'b')")
        psql("SELECT setval('public.workouts_id_seq',1,false)")
        psql(file=ROOT/'sql/reconcile-sequences.sql')
        self.assertEqual(psql("SELECT last_value FROM public.workouts_id_seq"),'17')
        self.assertEqual(psql("SELECT is_called FROM public.workouts_id_seq"),'t')
        result=subprocess.run(['psql','-XAt','-v','ON_ERROR_STOP=1','-1','-c',
            "INSERT INTO public.workouts(name) VALUES ('should_roll_back'); SELECT 1/0"],
            capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(psql('SELECT count(*) FROM public.workouts'),'2')

if __name__=='__main__': unittest.main()
