"""Non-secret policy shared by Ansible (YAML) and stdlib-only CI clients (JSON)."""
import json
import re
from pathlib import Path


def load_policy(path=None):
    path = path or Path(__file__).resolve().parents[1] / "config/sync.yml"
    policy = json.loads(Path(path).read_text())
    for name in ("sync_production_db", "sync_test_db", "sync_candidate_db", "sync_staging_db",
                 "sync_backup_role", "sync_loader_role"):
        if not re.fullmatch(r"[a-z][a-z0-9_]*", policy[name]):
            raise ValueError(f"Invalid identifier in policy: {name}")
    for name in ("sync_receiver_user", "sync_pg_admin_user", "sync_admin_user", "sync_production_ssh_user"):
        if not re.fullmatch(r"[a-z_][a-z0-9_-]*", policy[name]):
            raise ValueError(f"Invalid OS identity in policy: {name}")
    if not 1 <= policy['sync_pg_port'] <= 65535:
        raise ValueError("Invalid PostgreSQL port")
    targets = [policy[name] for name in ("sync_production_db", "sync_test_db", "sync_candidate_db", "sync_staging_db")]
    if len(set(targets)) != len(targets):
        raise ValueError("Database policy targets must be distinct")
    for name in ("sync_pg_port", "sync_max_dump_bytes", "sync_health_retries", "sync_health_delay"):
        if type(policy[name]) is not int or policy[name] < 1:
            raise ValueError(f"Invalid positive integer in policy: {name}")
    return policy


POLICY = load_policy()
