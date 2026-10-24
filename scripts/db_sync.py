"""Restricted GitLab database sync client; server authorization remains SSH forced-command.

No shell interpolation, no SQL execution from CI, no production dump artifacts.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from ci import PRODUCTION_SSH, RESTORE_SSH, endpoint_hosts, require_value, ssh_options
from policy import POLICY

OPERATIONS = (
    "verify-production",
    "backup-test",
    "verify-transport",
    "prepare-candidate",
    "restore-candidate",
    "sync-test",
)


ENDPOINTS = {
    "production": PRODUCTION_SSH,
    "test": RESTORE_SSH,
}


def endpoint(which: str, workdir: Path) -> list[str]:
    production, test = endpoint_hosts()
    identity = ENDPOINTS[which]
    key, hosts = identity.credentials(workdir, which)
    host = production if which == "production" else test
    return ["ssh", "-T", *ssh_options(key, hosts), f"{identity.user}@{host}"]


def check_archive(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError("Empty database backup")
    with path.open("rb") as stream:
        if stream.read(5) != b"PGDMP":
            raise ValueError("Unexpected PostgreSQL archive header")
    subprocess.run(
        ["pg_restore", "--list", str(path)], stdout=subprocess.DEVNULL, check=True
    )


def verify_production(prod: list[str], workdir: Path) -> None:
    path = workdir / "production.dump"
    with path.open("wb") as sink:
        subprocess.run(prod, stdout=sink, check=True)
    check_archive(path)
    print(
        f"Production backup verified (archive: {path.stat().st_size} bytes).",
        flush=True,
    )
    print("Backup not published as a GitLab artifact.", flush=True)


def backup_test(workdir: Path) -> None:
    if require_value("TEST_DB").strip() != POLICY["sync_test_db"]:
        raise ValueError("TEST_DB does not match repository policy")
    if os.environ.get("TEST_DB_PORT", str(POLICY["sync_pg_port"])) != str(POLICY["sync_pg_port"]):
        raise ValueError("TEST_DB_PORT does not match repository policy")
    password = require_value("TEST_DB_PASSWORD")
    path = workdir / "test.dump"
    env = os.environ.copy()
    env.update(
        PGHOST=require_value("TEST_DB_HOST").strip(),
        PGPORT=str(POLICY["sync_pg_port"]),
        PGUSER=POLICY["sync_backup_role"],
        PGDATABASE=POLICY["sync_test_db"],
        PGPASSWORD=password,
        PGCONNECT_TIMEOUT="10",
    )
    subprocess.run(
        [
            "pg_dump",
            "--format=custom",
            "--no-owner",
            "--no-acl",
            "--no-password",
            f"--file={path}",
        ],
        env=env,
        check=True,
    )
    check_archive(path)
    print(f"Test backup verified (archive: {path.stat().st_size} bytes).", flush=True)
    print("Backup not published as a GitLab artifact.", flush=True)


def forward_stream(prod: list[str], test: list[str]) -> None:
    # Both endpoints run fixed, restricted server-side programs.
    # Source stderr remains visible; no buffering of production credentials or dump.
    source = subprocess.Popen(prod, stdout=subprocess.PIPE)
    target = None
    try:
        assert source.stdout is not None
        try:
            target = subprocess.Popen(test, stdin=source.stdout)
        finally:
            source.stdout.close()
        target_code = target.wait()
        source_code = source.wait()
        if source_code or target_code:
            raise RuntimeError(
                f"SSH transfer failed (production={source_code}, test={target_code})"
            )
    finally:
        # Stop both ends before waiting, including launch failures or interruption.
        processes = [process for process in (target, source) if process is not None]
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=OPERATIONS)
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="workouts-db-sync-") as tmp:
            os.chmod(tmp, 0o700)
            workdir = Path(tmp)
            if args.operation == "backup-test":
                backup_test(workdir)
                return 0
            if args.operation == "verify-production":
                verify_production(endpoint("production", workdir), workdir)
            elif args.operation in ("verify-transport", "restore-candidate"):
                prod = endpoint("production", workdir)
                test = endpoint("test", workdir)
                command = test + (
                    ["restore-candidate"]
                    if args.operation == "restore-candidate"
                    else []
                )
                forward_stream(prod, command)
                print(
                    "Restricted production-to-test transfer completed:",
                    args.operation,
                    flush=True,
                )
            else:
                subprocess.run(endpoint("test", workdir) + [args.operation], check=True)
            return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
