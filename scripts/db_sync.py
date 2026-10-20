#!/usr/bin/env python3
"""Restricted GitLab database sync client; server authorization remains SSH forced-command.

No shell interpolation, no SQL execution from CI, no production dump artifacts.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


OPERATIONS = ('verify-production', 'backup-test', 'verify-transport',
              'prepare-candidate', 'restore-candidate', 'sync-test')


def secret_file(name: str, workdir: Path, target: str) -> Path:
    original = os.environ.get(name)
    if not original or not Path(original).is_file() or not Path(original).stat().st_size:
        raise ValueError(f'Missing or empty GitLab File variable: {name}')
    dest = workdir / target
    shutil.copyfile(original, dest)
    dest.chmod(0o600)
    return dest


def endpoint(which: str, workdir: Path) -> list[str]:
    if which == 'production':
        host = os.environ.get('PROD_HOST')
        if host != '2.29.51.66':
            raise ValueError('Unexpected production host')
        key = secret_file('PROD_BACKUP_SSH_KEY', workdir, 'prod_key')
        hosts = secret_file('PROD_SSH_KNOWN_HOSTS', workdir, 'prod_hosts')
        user = 'workouts-db-backup'
    else:
        host = os.environ.get('TEST_HOST')
        if host != '192.168.1.37':
            raise ValueError('Unexpected test host')
        key = secret_file('TEST_RESTORE_SSH_KEY', workdir, 'test_key')
        hosts = secret_file('TEST_RESTORE_SSH_KNOWN_HOSTS', workdir, 'test_hosts')
        user = 'workouts-db-restore'
    return [
        'ssh', '-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', f'UserKnownHostsFile={hosts}', '-i', str(key),
        f'{user}@{host}',
    ]


def check_archive(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError('Empty database backup')
    with path.open('rb') as stream:
        if stream.read(5) != b'PGDMP':
            raise ValueError('Unexpected PostgreSQL archive header')
    subprocess.run(['pg_restore', '--list', str(path)], stdout=subprocess.DEVNULL, check=True)


def verify_production(prod: list[str], workdir: Path) -> None:
    path = workdir / 'production.dump'
    with path.open('wb') as sink:
        subprocess.run(prod, stdout=sink, check=True)
    check_archive(path)
    print(f'Production backup verified (archive: {path.stat().st_size} bytes).', flush=True)
    print('Backup not published as a GitLab artifact.', flush=True)


def backup_test(workdir: Path) -> None:
    password = os.environ.get('TEST_DB_PASSWORD')
    if not password:
        raise ValueError('Missing TEST_DB_PASSWORD')
    path = workdir / 'test.dump'
    env = os.environ.copy()
    env.update(PGHOST='172.17.0.1', PGPORT='5432', PGUSER='workouts_db_sync',
               PGDATABASE='workouts_test', PGPASSWORD=password, PGCONNECT_TIMEOUT='10')
    subprocess.run(['pg_dump', '--format=custom', '--no-owner', '--no-acl',
                    '--no-password', f'--file={path}'], env=env, check=True)
    check_archive(path)
    print(f'Test backup verified (archive: {path.stat().st_size} bytes).', flush=True)
    print('Backup not published as a GitLab artifact.', flush=True)


def forward_stream(prod: list[str], test: list[str]) -> None:
    # Both endpoints run fixed, restricted server-side programs.
    # Source stderr remains visible; no buffering of production credentials or dump.
    source = subprocess.Popen(prod, stdout=subprocess.PIPE)
    try:
        assert source.stdout is not None
        try:
            target = subprocess.Popen(test, stdin=source.stdout)
        finally:
            source.stdout.close()
        target_code = target.wait()
        source_code = source.wait()
        if source_code or target_code:
            raise RuntimeError(f'SSH transfer failed (production={source_code}, test={target_code})')
    finally:
        if source.poll() is None:
            source.terminate()
            source.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=OPERATIONS)
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix='workouts-db-sync-') as tmp:
            os.chmod(tmp, 0o700)
            workdir = Path(tmp)
            if args.operation == 'backup-test':
                backup_test(workdir)
                return 0
            prod = endpoint('production', workdir) if args.operation in (
                'verify-production', 'verify-transport', 'restore-candidate') else None
            test = endpoint('test', workdir) if args.operation in (
                'verify-transport', 'restore-candidate', 'prepare-candidate', 'sync-test') else None
            if args.operation == 'verify-production':
                assert prod is not None
                verify_production(prod, workdir)
            elif args.operation in ('verify-transport', 'restore-candidate'):
                assert prod is not None and test is not None
                command = test + (['restore-candidate'] if args.operation == 'restore-candidate' else [])
                forward_stream(prod, command)
                print('Restricted production-to-test transfer completed:', args.operation, flush=True)
            else:
                assert test is not None
                remote_action = 'prepare-candidate' if args.operation == 'prepare-candidate' else 'sync-test'
                subprocess.run(test + [remote_action], check=True)
            return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
