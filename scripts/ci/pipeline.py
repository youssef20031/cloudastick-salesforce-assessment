#!/usr/bin/env python3
"""The small CI/CD engine behind .github/workflows: plan, drift guard, validate, deploy.

A pull request runs plan -> drift -> validate. Merging it runs deploy, which promotes
the validated build with a quick deploy, so the tests do not run a second time.

Commands share files under out/, and only the standard library and the sf and gh CLIs
are used. ORG is the alias the workflow logs in under.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

ORG = "abcDev"
OUT = pathlib.Path("out")
PLAN = OUT / "plan.json"
RESULT = OUT / "result.json"
CLASSES = pathlib.Path("force-app/main/default/classes")
MARKER = "abc-validated-job"
# Class names reach a SOQL query in the drift guard, so only plain Apex identifiers pass.
CLASS_PATH = re.compile(r"force-app/main/default/classes/([A-Za-z][A-Za-z0-9_]*)\.cls(?:-meta\.xml)?")


def run(*cmd, check=True):
    done = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if check and done.returncode != 0:
        sys.exit(f"{' '.join(cmd[:3])} failed:\n{done.stdout}\n{done.stderr}")
    return done


def sf_json(*cmd):
    """Runs sf with --json. A failed deploy still prints JSON, so the caller reads the result."""
    done = run("sf", *cmd, "--json", check=False)
    try:
        return json.loads(done.stdout)
    except json.JSONDecodeError:
        sys.exit(f"sf {cmd[0]} {cmd[1]} did not return JSON:\n{done.stdout}\n{done.stderr}")


def summary(text):
    print(text)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def output(name, value):
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def select_tests(changed_classes):
    """Each changed test, plus every test class that mentions a changed class by name."""
    selected = {name for name in changed_classes if name.endswith("Test")}
    production = [name for name in changed_classes if not name.endswith("Test")]
    for path in CLASSES.glob("*Test.cls"):
        source = path.read_text(encoding="utf-8")
        if any(name in source for name in production):
            selected.add(path.stem)
    return sorted(selected)


def plan(args):
    OUT.mkdir(exist_ok=True)
    listing = run("git", "diff", "--name-status", "--no-renames", f"{args.base}...{args.head}").stdout
    paths, deleted = [], []
    for line in listing.splitlines():
        status, path = line.split("\t", 1)
        if not path.startswith("force-app/"):
            continue
        (deleted if status == "D" else paths).append(path)

    classes = set()
    for path in paths:
        if ".cls" in path:
            match = CLASS_PATH.fullmatch(path)
            if not match:
                sys.exit(f"Stopped: not a valid Apex class path: {path}")
            classes.add(match.group(1))
    classes = sorted(classes)
    tests = select_tests(classes)
    PLAN.write_text(
        json.dumps({"base": args.base, "paths": paths, "classes": classes, "tests": tests}, indent=2),
        encoding="utf-8",
    )

    output("has_changes", "true" if paths else "false")
    summary("### Plan")
    if not paths:
        summary("No Salesforce changes in this range, so there is nothing to deploy.")
    else:
        summary(f"- **Components:** {', '.join(pathlib.Path(p).name for p in paths)}")
        summary(f"- **Tests selected:** {', '.join(tests) if tests else 'none'}")
    if deleted:
        summary(f"- **Deleted, and not applied by this pipeline:** {', '.join(deleted)}")


def normalise(source):
    return source.replace("\r\n", "\n").rstrip()


def drift(_args):
    """Stops the run when the org's copy of a changed class differs from what git says it should be."""
    planned = json.loads(PLAN.read_text(encoding="utf-8"))
    if not planned["classes"]:
        summary("### Drift guard\nNo Apex classes in this change.")
        return

    names = ",".join(f"'{name}'" for name in planned["classes"])
    response = sf_json(
        "data", "query", "--use-tooling-api", "--target-org", ORG,
        "--query", f"SELECT Name, Body FROM ApexClass WHERE Name IN ({names})",
    )
    org_bodies = {r["Name"]: r["Body"] for r in response["result"]["records"]}

    drifted = []
    for name in planned["classes"]:
        expected = run("git", "show", f"{planned['base']}:{CLASSES.as_posix()}/{name}.cls", check=False)
        if expected.returncode != 0:
            continue  # New in this change, so the org has nothing to compare.
        # A class git has but the org doesn't has drifted too.
        if name not in org_bodies or normalise(org_bodies[name]) != normalise(expected.stdout):
            drifted.append(name)

    summary("### Drift guard")
    if drifted:
        summary(f"**Stopped:** changed in the org outside git: {', '.join(drifted)}")
        sys.exit(1)
    summary(f"The org matches git for: {', '.join(planned['classes'])}")


def deploy_args(planned):
    args = ["--target-org", ORG, "--wait", "30"]
    for path in planned["paths"]:
        args += ["--source-dir", path]
    if planned["tests"]:
        args += ["--test-level", "RunSpecifiedTests"]
        for test in planned["tests"]:
            args += ["--tests", test]
    elif planned["classes"]:
        args += ["--test-level", "RunLocalTests"]
    else:
        args += ["--test-level", "NoTestRun"]
    return args


def report(result):
    """Prints test and coverage results for the classes in this change."""
    planned = json.loads(PLAN.read_text(encoding="utf-8"))
    run_result = (result.get("details") or {}).get("runTestResult") or {}
    summary(f"- **Tests:** {result.get('numberTestsCompleted', 0)} passed, {result.get('numberTestErrors', 0)} failed")

    coverage = run_result.get("codeCoverage") or []
    if isinstance(coverage, dict):
        coverage = [coverage]
    for row in coverage:
        if row.get("name") in planned["classes"]:
            total = int(row.get("numLocations") or 0)
            missed = int(row.get("numLocationsNotCovered") or 0)
            percent = round(100 * (total - missed) / total) if total else 100
            summary(f"- **Coverage, {row['name']}:** {percent}%")

    failures = run_result.get("failures") or []
    if isinstance(failures, dict):
        failures = [failures]
    for failure in failures:
        summary(f"- **Failed:** {failure.get('name')}.{failure.get('methodName')}: {failure.get('message')}")

    problems = (result.get("details") or {}).get("componentFailures") or []
    if isinstance(problems, dict):
        problems = [problems]
    for problem in problems:
        summary(f"- **Compile error:** {problem.get('fileName')} line {problem.get('lineNumber')}: {problem.get('problem')}")


def validate(_args):
    planned = json.loads(PLAN.read_text(encoding="utf-8"))
    response = sf_json("project", "deploy", "validate", *deploy_args(planned))
    result = response.get("result") or {}
    RESULT.write_text(json.dumps({"id": result.get("id"), "success": result.get("success")}), encoding="utf-8")

    summary("### Check-only deploy, tests and coverage")
    if not result:
        sys.exit(f"The validation did not run: {response.get('message')}")
    report(result)
    if not result.get("success"):
        sys.exit("The check-only deploy failed.")
    summary("Nothing has changed in the org yet. Merging this pull request deploys it.")

    # The merge reads this back to promote the validated build without rerunning tests.
    tag = f"<!-- {MARKER}:{result['id']}:{os.environ['HEAD_SHA']} -->"
    run(
        "gh", "pr", "comment", os.environ["PR_NUMBER"],
        "--body", f"Check-only deploy passed against abcDev. Merging deploys it.\n\n{tag}",
    )


def validated_job_id():
    """The build validated for the merged PR's final commit, or None to fall back to a full deploy.

    Anyone can comment on a public repo's PR, so only this workflow's own comment counts,
    and only when its id is well formed and it was written for the commit that was merged.
    """
    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    pulls = json.loads(run("gh", "api", f"repos/{repo}/commits/{sha}/pulls").stdout)
    merged = next((pull for pull in pulls if pull.get("merge_commit_sha") == sha), None)
    if not merged:
        return None
    number, head_sha = merged["number"], merged["head"]["sha"]
    comments = json.loads(run("gh", "api", f"repos/{repo}/issues/{number}/comments?per_page=100").stdout)
    pattern = re.compile(rf"<!-- {MARKER}:(0Af[0-9A-Za-z]{{12,15}}):{re.escape(head_sha)} -->")
    for comment in reversed(comments):
        if (comment.get("user") or {}).get("login") != "github-actions[bot]":
            continue
        match = pattern.search(comment.get("body") or "")
        if match:
            return match.group(1)
    return None


def deploy(_args):
    planned = json.loads(PLAN.read_text(encoding="utf-8"))
    summary("### Deploy to abcDev")

    job_id = validated_job_id()
    if job_id:
        response = sf_json("project", "deploy", "quick", f"--job-id={job_id}", "--target-org", ORG, "--wait", "30")
        if (response.get("result") or {}).get("success"):
            summary(f"Quick deploy of validated build `{job_id}` succeeded, with no tests rerun.")
            return
        summary(f"Quick deploy was refused ({response.get('message')}), so this is a full deploy with tests.")

    response = sf_json("project", "deploy", "start", *deploy_args(planned))
    result = response.get("result") or {}
    if not result:
        sys.exit(f"The deploy did not run: {response.get('message')}")
    report(result)
    if not result.get("success"):
        sys.exit("The deploy failed.")
    summary("Full deploy succeeded.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan_command = commands.add_parser("plan")
    plan_command.add_argument("--base", required=True)
    plan_command.add_argument("--head", required=True)
    plan_command.set_defaults(handler=plan)
    for name, handler in (("drift", drift), ("validate", validate), ("deploy", deploy)):
        commands.add_parser(name).set_defaults(handler=handler)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
