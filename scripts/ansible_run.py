#!/usr/bin/env python3
"""Small CI credential launcher. Server configuration remains in Ansible."""
from __future__ import annotations

import os
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
    if len(sys.argv) != 2 or sys.argv[1] not in {"bootstrap", "verify"}:
        print("Usage: ansible_run.py bootstrap|verify", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    try:
        admin_key = require_file("ANSIBLE_BOOTSTRAP_SSH_KEY")
        hosts = require_file("ANSIBLE_BOOTSTRAP_KNOWN_HOSTS")
        if not os.environ.get("ANSIBLE_BECOME_PASSWORD"):
            raise ValueError("Required masked GitLab variable missing: ANSIBLE_BECOME_PASSWORD")
        restore_key = require_file("TEST_RESTORE_SSH_KEY") if mode == "bootstrap" else None
        if mode == "bootstrap":
            require_file("TEST_RESTORE_SSH_KNOWN_HOSTS")
        with tempfile.TemporaryDirectory(prefix="workouts-ansible-") as d:
            tmp = Path(d)
            for source, dest in ((admin_key, "admin.key"), (hosts, "known_hosts")):
                shutil.copyfile(source, tmp / dest)
                (tmp / dest).chmod(0o600)
            env = os.environ.copy()
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
            playbook = "ansible/bootstrap.yml" if mode == "bootstrap" else "ansible/verify-result.yml"
            return subprocess.run(
                ["ansible-playbook", "-i", "ansible/inventory.ini", playbook],
                check=False, env=env,
            ).returncode
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
