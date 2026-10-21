"""Offline checks for pipeline ordering, approval and exclusive server access."""

import unittest
from itertools import pairwise
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load_yaml(path):
    return yaml.safe_load((ROOT / path).read_text())


def ancestors(config, name, visiting=frozenset()):
    if name in visiting:
        raise ValueError(f"Dependency cycle at {name}")
    jobs = {
        key: value
        for key, value in config.items()
        if isinstance(value, dict) and "stage" in value
    }
    stages = {stage: index for index, stage in enumerate(config["stages"])}
    job = jobs[name]
    if "needs" in job:
        dependencies = job["needs"]
        if not dependencies or not all(isinstance(item, str) for item in dependencies):
            raise ValueError(f"{name} must have mandatory dependencies")
    else:
        dependencies = [
            other
            for other, value in jobs.items()
            if stages[value["stage"]] < stages[job["stage"]]
        ]
    result = set()
    for dependency in dependencies:
        if stages[jobs[dependency]["stage"]] > stages[job["stage"]]:
            raise ValueError(f"{name} depends on a later stage")
        result.add(dependency)
        result.update(ancestors(config, dependency, visiting | {name}))
    return result


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.parent = load_yaml(".gitlab-ci.yml")
        self.child = load_yaml("ci/sync.yml")

    def test_all_server_work_is_inside_the_locked_child(self):
        refresh = self.parent["refresh_test_database"]
        self.assertEqual(refresh["resource_group"], "workouts-refresh-pipeline")
        self.assertIn(refresh["trigger"]["strategy"], ("depend", "mirror"))
        self.assertEqual(refresh["trigger"]["include"], [{"local": "ci/sync.yml"}])
        self.assertTrue(refresh["trigger"]["forward"]["pipeline_variables"])
        self.assertEqual(
            refresh["variables"]["WORKOUTS_PIPELINE_SOURCE"], "$CI_PIPELINE_SOURCE"
        )
        self.assertIn("preflight", ancestors(self.parent, "refresh_test_database"))
        for name, job in self.parent.items():
            if (
                isinstance(job, dict)
                and "stage" in job
                and name != "refresh_test_database"
            ):
                self.assertEqual(job["stage"], "validate", name)
        for name, job in self.child.items():
            if isinstance(job, dict) and "stage" in job:
                # A child requesting the parent's resource would deadlock.
                self.assertNotIn("resource_group", job, name)
        self.assertIn("parent_pipeline", self.child["workflow"]["rules"][0]["if"])

    def test_validation_finishes_before_preflight(self):
        self.assertTrue(
            {"validate_repository", "postgresql_integration"}
            <= ancestors(self.parent, "preflight")
        )

    def test_server_operations_cannot_bypass_required_predecessors(self):
        sequence = [
            "ansible_bootstrap",
            "verify_production_backup",
            "backup_test_database",
            "verify_test_restore_ssh",
            "prepare_candidate",
            "restore_production_to_candidate",
            "sync_candidate_to_test",
            "verify_sync_result",
        ]
        for previous, current in pairwise(sequence):
            with self.subTest(job=current):
                self.assertIn(previous, ancestors(self.child, current))

    def test_push_requires_approval_and_web_runs_automatically(self):
        push, web, fallback = self.child["restore_production_to_candidate"]["rules"]
        self.assertIn('$WORKOUTS_PIPELINE_SOURCE == "push"', push["if"])
        self.assertEqual(push["when"], "manual")
        self.assertIs(push["allow_failure"], False)
        self.assertIn('$WORKOUTS_PIPELINE_SOURCE == "web"', web["if"])
        self.assertEqual(web["when"], "on_success")
        self.assertEqual(fallback["when"], "never")

    def test_client_commands_still_use_restricted_entrypoints(self):
        commands = {
            "ansible_bootstrap": "ansible_run.py bootstrap",
            "verify_production_backup": "db_sync.py verify-production",
            "backup_test_database": "db_sync.py backup-test",
            "verify_test_restore_ssh": "db_sync.py verify-transport",
            "prepare_candidate": "db_sync.py prepare-candidate",
            "restore_production_to_candidate": "db_sync.py restore-candidate",
            "sync_candidate_to_test": "db_sync.py sync-test",
            "verify_sync_result": "ansible_run.py verify",
        }
        for name, command in commands.items():
            self.assertEqual(self.child[name]["script"], [f"python3 scripts/{command}"])
        self.assertEqual(
            self.parent["preflight"]["script"],
            ["python3 scripts/ansible_run.py preflight"],
        )
        for endpoint in ("PROD_HOST", "TEST_HOST"):
            self.assertNotIn(endpoint, self.parent.get("variables", {}))


class AnsibleAssetsTests(unittest.TestCase):
    def test_candidate_ownership_remains_conditional_and_postconditions_are_checked(
        self,
    ):
        tasks = {
            task.get("name"): task
            for task in load_yaml("ansible/tasks/bootstrap/postgresql.yml")
        }
        self.assertTrue(tasks["Set candidate owner only if needed"]["when"])
        verify = load_yaml("ansible/verify-result.yml")[0]
        check = next(
            task for task in verify["tasks"] if "ansible.builtin.assert" in task
        )
        self.assertIn(
            "candidate_state.stdout | trim == '0|0|1'",
            check["ansible.builtin.assert"]["that"],
        )

    def test_all_playbooks_and_task_files_parse(self):
        for path in (ROOT / "ansible").rglob("*.yml"):
            with self.subTest(path=path):
                self.assertIsInstance(yaml.safe_load(path.read_text()), list)
        play = load_yaml("ansible/bootstrap.yml")[0]
        for task in play["tasks"]:
            self.assertTrue(
                (ROOT / "ansible" / task["ansible.builtin.import_tasks"]).is_file()
            )

    def test_installed_scripts_remain_root_owned_and_executable(self):
        tasks = load_yaml("ansible/tasks/bootstrap/receiver.yml")
        install = next(
            task["ansible.builtin.copy"]
            for task in tasks
            if task.get("name")
            == "Copy only audited root-owned fixed-purpose entrypoints"
        )
        self.assertEqual(
            (install["owner"], install["group"], install["mode"]),
            ("root", "root", "0755"),
        )
        for task in tasks:
            if (
                task.get("name")
                == "Copy only audited root-owned fixed-purpose entrypoints"
            ):
                for name in task["loop"]:
                    self.assertTrue((ROOT / "scripts/server" / name).is_file())
