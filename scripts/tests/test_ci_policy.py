import contextlib
from copy import deepcopy
import io
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_policy as ci


class ChangedFilesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "CI Test")
        self.git("config", "user.email", "ci@example.test")
        for path in ("README.md", "site/index.html", "wooloo/App.swift"):
            self.write(path)
        self.base = self.commit()

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["git", *args], cwd=self.root, env=env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, name, text="first\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Change")
        return self.git("rev-parse", "HEAD")

    def requires_tests(self, head, base=None):
        return ci.requires_tests("pull_request", base or self.base, head, self.root)

    def test_only_explicit_docs_and_site_paths_are_exempt(self):
        self.write("README.md", "updated\n")
        self.write("TODO.md")
        self.write("site/assets/file with\na newline.png")
        self.assertFalse(self.requires_tests(self.commit()))

    def test_unknown_and_functional_paths_run_tests_even_when_markdown(self):
        for path in ["docs/guide.md", "Vendor/Package/README.md", "wooloo/Assets/icon.png",
                     "woolooTests/Test.swift", "scripts/tool.py", ".github/workflows/ci.yml",
                     "wooloo.xcodeproj/project.pbxproj", "new-folder/file"]:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                self.assertTrue(self.requires_tests(self.commit()))

    def test_earlier_code_commit_is_not_hidden_by_last_docs_commit(self):
        self.write("wooloo/App.swift", "changed\n")
        self.commit()
        self.write("README.md", "updated\n")
        self.assertTrue(self.requires_tests(self.commit()))

    def test_advancing_base_does_not_count_unrelated_main_changes(self):
        self.git("checkout", "-qb", "pr")
        self.write("README.md", "PR\n")
        head = self.commit()
        self.git("checkout", "main")
        self.write("wooloo/App.swift", "unrelated main change\n")
        self.assertFalse(self.requires_tests(head, self.commit()))

    def test_renaming_code_into_site_still_runs_tests(self):
        self.git("mv", "wooloo/App.swift", "site/App.swift")
        self.assertTrue(self.requires_tests(self.commit()))

    def test_renaming_site_into_app_runs_tests(self):
        self.git("mv", "site/index.html", "wooloo/index.html")
        self.assertTrue(self.requires_tests(self.commit()))

    def test_deleting_code_runs_tests(self):
        (self.root / "wooloo/App.swift").unlink()
        self.assertTrue(self.requires_tests(self.commit()))

    def test_empty_diff_runs_tests(self):
        self.assertTrue(self.requires_tests(self.base))

    def test_main_push_always_runs_tests_without_needing_a_diff(self):
        with patch.object(ci.subprocess, "run", side_effect=AssertionError("No diff needed")):
            self.assertTrue(ci.requires_tests("push", "", "", self.root))

    def test_invalid_missing_and_unavailable_commits_run_tests(self):
        for base in ("", "--help", "f" * 40):
            with self.subTest(base=base):
                self.assertTrue(ci.requires_tests("pull_request", base, self.base, self.root))

    def test_incomplete_and_non_utf8_diff_run_tests(self):
        for diff in [b"README.md", b"site/\xff\0", b"README.md\0\0"]:
            with self.subTest(diff=diff), patch.object(ci.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0, self.base + "\n"),
                subprocess.CompletedProcess([], 0, diff),
            ]):
                self.assertTrue(self.requires_tests(self.base))


class RequiredCheckTests(unittest.TestCase):
    def test_only_completed_tests_or_intentional_pr_skip_can_pass(self):
        allowed = {("pull_request", "success", "true", "success"),
                   ("push", "success", "true", "success"),
                   ("pull_request", "success", "false", "skipped")}
        for args in itertools.product(
            ("pull_request", "push"), ("success", "failure", "cancelled", "skipped", ""),
            ("true", "false", "", "unexpected"), ("success", "failure", "cancelled", "skipped", ""),
        ):
            with self.subTest(args=args):
                self.assertEqual(ci.ci_succeeded(*args), args in allowed)

    def test_cli_fails_with_missing_results(self):
        with patch.dict(os.environ, {}, clear=True), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ci.main(["result"]), 1)

    def test_changes_cli_writes_only_a_boolean_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_OUTPUT": str(output)}
            with patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ci.main(["changes"]), 0)
            self.assertEqual(output.read_text(), "run_tests=true\n")


class ReleaseCITests(unittest.TestCase):
    sha = "a" * 40

    def setUp(self):
        self.run = dict(id=100, run_attempt=2, path=".github/workflows/ci.yml", event="push",
                        head_branch="main", head_sha=self.sha, status="completed", conclusion="success")
        self.job = dict(name=ci.MACOS_JOB, status="completed", conclusion="success", labels=["macos-26"],
                        steps=[dict(name=name, status="completed", conclusion="success")
                               for name in ["Test", "Audit migrated concurrency boundaries"]])

    def check(self, runs=None, jobs=None):
        pages = [[self.run] if runs is None else runs, [self.job] if jobs is None else jobs]
        with patch.object(ci, "github_pages", side_effect=pages) as api:
            result = ci.release_ci_succeeded("owner/repo", self.sha)
        return result, api

    def test_success_requires_push_main_exact_sha_and_real_tests(self):
        passed, api = self.check()
        self.assertTrue(passed)
        self.assertIn("actions/workflows/ci.yml/runs?", api.call_args_list[0].args[0])
        self.assertIn("head_sha=" + self.sha, api.call_args_list[0].args[0])
        self.assertIn("/runs/100/attempts/2/jobs?", api.call_args_list[1].args[0])

    def test_pr_other_workflow_branch_sha_and_unfinished_runs_are_rejected(self):
        for field, value in [("event", "pull_request"), ("path", ".github/workflows/other.yml"),
                             ("head_branch", "feature"), ("head_sha", "b" * 40),
                             ("status", "in_progress"), ("conclusion", "failure"),
                             ("conclusion", "cancelled"), ("conclusion", "skipped")]:
            with self.subTest(field=field, value=value):
                self.assertFalse(self.check(runs=[dict(self.run, **{field: value})])[0])

    def test_aggregate_only_skipped_failed_or_wrong_runner_jobs_are_rejected(self):
        for field, value in [("name", "Build and test"), ("conclusion", "skipped"),
                             ("conclusion", "failure"), ("conclusion", "cancelled"),
                             ("status", "in_progress"), ("labels", ["ubuntu-latest"]), ("steps", [])]:
            with self.subTest(field=field, value=value):
                self.assertFalse(self.check(jobs=[dict(self.job, **{field: value})])[0])
        self.assertFalse(self.check(jobs=[])[0])
        self.assertFalse(self.check(runs=[])[0])

    def test_green_job_with_test_or_audit_step_skipped_is_rejected(self):
        for index in range(2):
            job = deepcopy(self.job)
            job["steps"][index]["conclusion"] = "skipped"
            with self.subTest(step=index):
                self.assertFalse(self.check(jobs=[job])[0])

    def test_invalid_run_identifiers_and_release_inputs_fail_closed(self):
        for field, value in [("id", None), ("id", "100"), ("run_attempt", 0), ("id", True)]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.check(runs=[dict(self.run, **{field: value})])
        for repository, sha in [("owner/repo/other", self.sha), ("owner/repo", "--help")]:
            with self.subTest(repository=repository), self.assertRaises(ValueError):
                ci.release_ci_succeeded(repository, sha)

    def test_pagination_includes_later_runs_and_jobs(self):
        responses = [[{"workflow_runs": []}, {"workflow_runs": [self.run]}],
                     [{"jobs": [dict(self.job, name="Build and test")]}, {"jobs": [self.job]}]]
        with patch.object(ci.subprocess, "run", side_effect=[
            subprocess.CompletedProcess([], 0, json.dumps(pages)) for pages in responses
        ]) as command:
            self.assertTrue(ci.release_ci_succeeded("owner/repo", self.sha))
        for call in command.call_args_list:
            self.assertIn("--paginate", call.args[0])
            self.assertIn("--slurp", call.args[0])

    def test_malformed_api_responses_are_not_evidence(self):
        for payload in [[], {}, [None], [{"jobs": None}], [{"jobs": ["invalid"]}]]:
            with self.subTest(payload=payload), patch.object(ci.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, json.dumps(payload))), self.assertRaises(ValueError):
                ci.github_pages("repos/owner/repo/actions/runs/100/jobs", "jobs")

    def test_api_errors_cannot_approve_release(self):
        env = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_SHA": self.sha}
        with patch.dict(os.environ, env, clear=True), contextlib.redirect_stderr(io.StringIO()), \
                patch.object(ci.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["gh"])):
            self.assertEqual(ci.main(["release"]), 1)


if __name__ == "__main__":
    unittest.main()
