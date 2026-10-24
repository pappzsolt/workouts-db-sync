"""Shared GitLab inputs and SSH credentials for the CI entrypoints."""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path

from policy import POLICY

PROJECT_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class SSHIdentity:
    user: str
    key_variable: str
    known_hosts_variable: str

    def credentials(self, workdir: Path, prefix: str) -> tuple[Path, Path]:
        return (
            secret_file(self.key_variable, workdir, f"{prefix}.key"),
            secret_file(self.known_hosts_variable, workdir, f"{prefix}.known_hosts"),
        )


BOOTSTRAP_SSH = SSHIdentity(
    POLICY["sync_admin_user"], "ANSIBLE_BOOTSTRAP_SSH_KEY", "ANSIBLE_BOOTSTRAP_KNOWN_HOSTS"
)
PRODUCTION_SSH = SSHIdentity(
    POLICY["sync_production_ssh_user"], "PROD_BACKUP_SSH_KEY", "PROD_SSH_KNOWN_HOSTS"
)
RESTORE_SSH = SSHIdentity(
    POLICY["sync_receiver_user"], "TEST_RESTORE_SSH_KEY", "TEST_RESTORE_SSH_KNOWN_HOSTS"
)
CI_FILE_VARIABLES = tuple(
    variable
    for identity in (BOOTSTRAP_SSH, PRODUCTION_SSH, RESTORE_SSH)
    for variable in (identity.key_variable, identity.known_hosts_variable)
)
CI_VALUE_VARIABLES = (
    "ANSIBLE_BECOME_PASSWORD",
    "PROD_HOST",
    "TEST_HOST",
    "TEST_DB_HOST",
    "TEST_DB_PASSWORD",
)


def require_value(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        raise ValueError(f"Required GitLab variable missing or empty: {name}")
    return value


def require_file(name: str) -> Path:
    # Report only the variable name, including when a value is not a valid path.
    try:
        path = Path(require_value(name))
        if path.is_file() and path.stat().st_size:
            return path
    except (OSError, ValueError):
        pass
    raise ValueError(f"Missing or empty GitLab File variable: {name}")


def secret_file(name: str, workdir: Path, target: str) -> Path:
    source = require_file(name)
    dest = workdir / target
    # Restrict permissions before writing, independently of the process umask.
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as sink, source.open("rb") as stream:
        shutil.copyfileobj(stream, sink)
    return dest


def validate_ci_variables() -> None:
    for name in CI_VALUE_VARIABLES:
        require_value(name)
    for name in CI_FILE_VARIABLES:
        require_file(name)


def endpoint_hosts() -> tuple[str, str]:
    production = require_value("PROD_HOST").strip()
    test = require_value("TEST_HOST").strip()
    if production == test:
        raise ValueError("Production and test endpoints must be different")
    return production, test


def ssh_options(key: Path, known_hosts: Path) -> list[str]:
    return [
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-i",
        str(key),
    ]
