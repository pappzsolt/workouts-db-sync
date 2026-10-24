"""Offline checks for automatic pipeline ordering and exclusive server access."""

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

    def test_push_and_web_sync_without_manual_jobs(self):
        push, web, fallback = self.parent["workflow"]["rules"]
        self.assertIn('$CI_PIPELINE_SOURCE == "push"', push["if"])
        self.assertIn('$CI_PIPELINE_SOURCE == "web"', web["if"])
        self.assertEqual(push["when"], "always")
        self.assertEqual(web["when"], "always")
        self.assertEqual(fallback["when"], "never")
        restore, fallback = self.child["restore_production_to_candidate"]["rules"]
        self.assertEqual(restore["if"], '$CI_COMMIT_BRANCH == "main"')
        self.assertEqual(restore["when"], "on_success")
        self.assertEqual(fallback["when"], "never")
        for config in (self.parent, self.child):
            for name, job in config.items():
                if isinstance(job, dict) and "stage" in job:
                    with self.subTest(job=name):
                        self.assertNotEqual(job.get("when"), "manual")
                        self.assertTrue(
                            all(
                                rule.get("when") != "manual"
                                for rule in job.get("rules", [])
                            )
                        )

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
                expected_type = dict if path.parent.name == "vars" else list
                self.assertIsInstance(yaml.safe_load(path.read_text()), expected_type)
        play = load_yaml("ansible/bootstrap.yml")[0]
        for task in play["tasks"]:
            if "ansible.builtin.import_tasks" in task:
                self.assertTrue((ROOT / "ansible" / task["ansible.builtin.import_tasks"]).is_file())

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


class VerificationPolicyTests(unittest.TestCase):
    def evaluate(self, expression, **values):
        import jinja2
        environment = jinja2.Environment()
        environment.filters['split'] = lambda value, sep: value.split(sep)
        return environment.compile_expression(expression)(**values)

    def test_empty_business_tables_are_valid_but_missing_migrations_are_not(self):
        verify = load_yaml('ansible/verify-result.yml')[0]
        expressions = next(t['ansible.builtin.assert']['that'] for t in verify['tasks'] if 'ansible.builtin.assert' in t)
        for counts, expected in [('0|0|0|42',True),('1|2|3|42',True),('0|0|0|0',False),('0|0|42',False)]:
            with self.subTest(counts=counts):
                valid = all(self.evaluate(e,candidate_state={'stdout':'0|0|1'},test_counts={'stdout':counts},api_running={'stdout':'true|healthy'}) for e in expressions)
                self.assertEqual(valid,expected)

    def test_running_but_unhealthy_api_is_not_accepted(self):
        verify = load_yaml('ansible/verify-result.yml')[0]
        health = next(t for t in verify['tasks'] if t.get('register')=='api_running')
        for status, expected in [('true|healthy',True),('false|healthy',False),('true|starting',False),('true|unhealthy',False),('true|missing',False),('true',False)]:
            with self.subTest(status=status):
                self.assertEqual(self.evaluate(health['until'],api_running={'rc':0,'stdout':status}),expected)
        self.assertIn('sync_health_retries',health['retries'])

    def test_recovery_is_not_available_to_the_restricted_ssh_identity(self):
        dispatcher = (ROOT/'scripts/server/restore-dispatch.sh').read_text()
        sudoers = next(t['ansible.builtin.copy']['content'] for t in load_yaml('ansible/tasks/bootstrap/receiver.yml') if t.get('name')=='Limit passwordless sudo to two immutable server-side programs')
        self.assertNotIn('reset-candidate',dispatcher)
        self.assertNotIn('reset-candidate',sudoers)
