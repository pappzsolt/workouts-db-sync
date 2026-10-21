"""Small CI credential launcher. Server configuration remains in Ansible."""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

from ci import (
    endpoint_hosts,
    require_value,
    secret_file,
    ssh_options,
    validate_ci_variables,
)

PLAYBOOKS = {
    "bootstrap": "ansible/bootstrap.yml",
    "preflight": "ansible/preflight.yml",
    "verify": "ansible/verify-result.yml",
}


def inventory(production: str, test: str) -> dict:
    return {
        "all": {
            "children": {
                "workouts_production": {
                    "hosts": {
                        "production": {
                            "ansible_host": production,
                            "ansible_user": "workouts-db-backup",
                        }
                    }
                },
                "workouts_test": {
                    "hosts": {
                        "test": {
                            "ansible_host": test,
                            "ansible_user": "pappzs",
                            "ansible_python_interpreter": "/usr/bin/python3",
                        }
                    }
                },
            }
        }
    }


def remote_environment(workdir: Path, mode: str) -> dict[str, str]:
    require_value("ANSIBLE_BECOME_PASSWORD")
    key = secret_file("ANSIBLE_BOOTSTRAP_SSH_KEY", workdir, "admin.key")
    hosts = secret_file("ANSIBLE_BOOTSTRAP_KNOWN_HOSTS", workdir, "known_hosts")
    env = os.environ.copy()
    env.update(
        {
            "ANSIBLE_HOST_KEY_CHECKING": "True",
            "ANSIBLE_PRIVATE_KEY_FILE": str(key),
            "ANSIBLE_SSH_COMMON_ARGS": shlex.join(ssh_options(key, hosts)),
        }
    )
    if mode == "bootstrap":
        key = secret_file("TEST_RESTORE_SSH_KEY", workdir, "restore.key")
        pub = subprocess.run(
            ["ssh-keygen", "-y", "-f", str(key)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if not pub.startswith("ssh-ed25519 "):
            raise ValueError("Unexpected restore SSH key type")
        env["WORKOUTS_RESTORE_PUBKEY"] = pub
    return env


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in PLAYBOOKS:
        print("Usage: ansible_run.py bootstrap|preflight|verify", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    try:
        if mode == "preflight":
            validate_ci_variables()
        production, test = endpoint_hosts()
        with tempfile.TemporaryDirectory(prefix="workouts-ansible-") as directory:
            workdir = Path(directory)
            inventory_path = workdir / "inventory.json"
            inventory_path.write_text(
                json.dumps(inventory(production, test)), encoding="utf-8"
            )
            env = (
                os.environ.copy()
                if mode == "preflight"
                else remote_environment(workdir, mode)
            )
            return subprocess.run(
                ["ansible-playbook", "-i", str(inventory_path), PLAYBOOKS[mode]],
                check=False,
                env=env,
            ).returncode
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
