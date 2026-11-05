#!/usr/bin/env python3
"""Classify PR changes, enforce the required CI check, and verify release CI."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


MACOS_JOB = "macOS build and test"
SHA = re.compile(r"[0-9a-f]{40}")


def docs_only(paths):
    # Unknown paths run the full suite. In particular, Markdown inside Vendor is
    # not exempt, and scripts/workflows/resources are never classified as docs.
    return bool(paths) and all(
        path in {"README.md", "TODO.md"}
        or (path.startswith("site/") and all(part not in {"", ".", ".."} for part in path.split("/")))
        for path in paths
    )


def requires_tests(event, base, head, root):
    if event != "pull_request":
        return True
    try:
        if not SHA.fullmatch(base) or not SHA.fullmatch(head):
            raise ValueError("Missing or invalid PR commit SHA")
        ancestor = subprocess.run(
            ["git", "merge-base", base, head], cwd=root, check=True,
            capture_output=True, text=True, timeout=60,
        ).stdout.strip()
        if not SHA.fullmatch(ancestor):
            raise ValueError("Invalid merge base")
        diff = subprocess.run(
            ["git", "diff", "--no-renames", "--name-only", "-z", ancestor, head, "--"],
            cwd=root, check=True, capture_output=True, timeout=60,
        ).stdout
        if not diff or not diff.endswith(b"\0"):
            raise ValueError("Empty or incomplete changed-file list")
        return not docs_only(diff[:-1].decode("utf-8").split("\0"))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Cannot safely classify the PR; running the full suite: {error}", file=sys.stderr)
        return True


def ci_succeeded(event, changes_result, run_tests, test_result):
    if changes_result != "success":
        return False
    if run_tests == "true":
        return test_result == "success"
    return event == "pull_request" and run_tests == "false" and test_result == "skipped"


def github_pages(endpoint, key):
    result = subprocess.run(
        ["gh", "api", endpoint, "--paginate", "--slurp"],
        check=True, capture_output=True, text=True, timeout=60,
    )
    pages = json.loads(result.stdout)
    if not isinstance(pages, list) or not pages:
        raise ValueError("Missing GitHub API pages")
    items = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get(key), list):
            raise ValueError(f"Invalid GitHub API page: expected {key}")
        if any(not isinstance(item, dict) for item in page[key]):
            raise ValueError(f"Invalid GitHub API {key}")
        items.extend(page[key])
    return items


def release_ci_succeeded(repository, sha):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not SHA.fullmatch(sha):
        raise ValueError("Missing or invalid release repository/SHA")
    endpoint = (
        f"repos/{repository}/actions/workflows/ci.yml/runs"
        f"?per_page=100&event=push&branch=main&head_sha={sha}&status=success"
    )
    for run in github_pages(endpoint, "workflow_runs"):
        if not (
            run.get("path") == ".github/workflows/ci.yml"
            and run.get("event") == "push" and run.get("head_branch") == "main"
            and run.get("head_sha") == sha
            and run.get("status") == "completed" and run.get("conclusion") == "success"
        ):
            continue
        run_id, attempt = run.get("id"), run.get("run_attempt")
        if type(run_id) is not int or run_id <= 0 or type(attempt) is not int or attempt <= 0:
            raise ValueError("Missing or invalid CI run/attempt ID")
        jobs = github_pages(
            f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", "jobs",
        )
        for job in jobs:
            if (job.get("name") == MACOS_JOB and job.get("status") == "completed"
                    and job.get("conclusion") == "success" and "macos-26" in job.get("labels", [])):
                steps = job.get("steps", [])
                if all(any(step.get("name") == name and step.get("conclusion") == "success"
                           and step.get("status") == "completed" for step in steps)
                       for name in ("Test", "Audit migrated concurrency boundaries")):
                    return True
    return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("changes", "result", "release"))
    args = parser.parse_args(argv)
    env = os.environ
    try:
        if args.command == "changes":
            run = requires_tests(
                env.get("GITHUB_EVENT_NAME", ""), env.get("PR_BASE_SHA", ""),
                env.get("PR_HEAD_SHA", ""), Path.cwd(),
            )
            value = "true" if run else "false"
            with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write(f"run_tests={value}\n")
            print("Run the full macOS suite." if run else "PR changes only README.md, TODO.md or site/; macOS omitted.")
            return 0
        if args.command == "result":
            if ci_succeeded(env.get("GITHUB_EVENT_NAME", ""), env.get("CHANGES_RESULT", ""),
                            env.get("RUN_TESTS", ""), env.get("TEST_RESULT", "")):
                print("CI passed (full suite or explicitly permitted documentation-only PR).")
                return 0
            print("CI failed: classification or required macOS tests did not complete as expected.", file=sys.stderr)
            return 1
        if release_ci_succeeded(env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_SHA", "")):
            print("Release commit passed the full macOS suite in a CI push to main.")
            return 0
        print("CI has not passed the full suite on this main commit; wait for it, then push the tag again.",
              file=sys.stderr)
        return 1
    except (KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"CI policy failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
