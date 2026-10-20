#!/usr/bin/env python3
"""Small CI credential launcher. Server configuration remains in Ansible."""
from __future__ import annotations

import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def require_file(key: str) -> Path:
    name = os.environ.get(key)
    if not name:
        raise ValueError(f"Required GitLab File variable missing: {key}")
    path = Path(name)
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"Required GitLab File variable empty: {key}")
    return path


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"bootstrap", "preflight", "verify"}:
        print("Usage: ansible_run.py bootstrap|preflight|verify", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    try:
        admin_key = require_file("ANSIBLE_BOOTSTRAP_SSH_KEY") if mode != "preflight" else None
        hosts = require_file("ANSIBLE_BOOTSTRAP_KNOWN_HOSTS") if mode != "preflight" else None
        if mode != "preflight" and not os.environ.get("ANSIBLE_BECOME_PASSWORD"):
            raise ValueError("Required masked GitLab variable missing: ANSIBLE_BECOME_PASSWORD")
        prod_host = os.environ.get("PROD_HOST", "").strip()
        test_host = os.environ.get("TEST_HOST", "").strip()
        if not prod_host or not test_host or prod_host == test_host:
            raise ValueError("PROD_HOST and TEST_HOST must be nonempty and different")
        restore_key = require_file("TEST_RESTORE_SSH_KEY") if mode == "bootstrap" else None
        if mode == "bootstrap":
            require_file("TEST_RESTORE_SSH_KNOWN_HOSTS")
        with tempfile.TemporaryDirectory(prefix="workouts-ansible-") as d:
            tmp = Path(d)
            inventory = {
                "all": {"children": {
                    "workouts_production": {"hosts": {"production": {
                        "ansible_host": prod_host, "ansible_user": "workouts-db-backup"}}},
                    "workouts_test": {"hosts": {"test": {
                        "ansible_host": test_host, "ansible_user": "pappzs",
                        "ansible_python_interpreter": "/usr/bin/python3"}}},
                }}
            }
            inventory_path = tmp / "inventory.json"
            inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
            env = os.environ.copy()
            if admin_key is not None and hosts is not None:
                for source, dest in ((admin_key, "admin.key"), (hosts, "known_hosts")):
                    shutil.copyfile(source, tmp / dest)
                    (tmp / dest).chmod(0o600)
                env.update({
                    "ANSIBLE_HOST_KEY_CHECKING": "True",
                    "ANSIBLE_PRIVATE_KEY_FILE": str(tmp / "admin.key"),
                    "ANSIBLE_SSH_COMMON_ARGS": (
                        "-o BatchMode=yes -o IdentitiesOnly=yes "
                        "-o StrictHostKeyChecking=yes "
                        f"-o UserKnownHostsFile={tmp / 'known_hosts'}"
                    ),
                })
            if restore_key is not None:
                shutil.copyfile(restore_key, tmp / "restore.key")
                (tmp / "restore.key").chmod(0o600)
                pub = subprocess.run(
                    ["ssh-keygen", "-y", "-f", str(tmp / "restore.key")],
                    check=True, capture_output=True, text=True,
                ).stdout.strip()
                if not pub.startswith("ssh-ed25519 "):
                    raise ValueError("Unexpected restore SSH key type")
                env["WORKOUTS_RESTORE_PUBKEY"] = pub
            playbook = {
                "bootstrap": "ansible/bootstrap.yml",
                "preflight": "ansible/preflight.yml",
                "verify": "ansible/verify-result.yml",
            }[mode]
            return subprocess.run(
                ["ansible-playbook", "-i", str(inventory_path), playbook],
                check=False, env=env,
            ).returncode
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
