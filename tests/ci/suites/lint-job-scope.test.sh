#!/usr/bin/env bash
# Execute the shipped scope steps over real merge commits. Removing a step
# guard must start unnecessary work; trusting the PR helper must skip lint.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$HERE" <<'PY'
import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

root = Path(sys.argv[1])
helper = "scripts/quality/ci-job-scope.sh"
specs = {
    "shellcheck": ("reusable-shell-ci.yml", "shellcheck"),
    "workflow-lint": ("reusable-workflow-lint.yml", "workflow-lint"),
    "line-limit": ("reusable-line-limit.yml", "line-limit"),
}
passed = failed = 0


def check(name, want, got):
    global passed, failed
    if want == got:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}: expected {want!r}, got {got!r}")


with tempfile.TemporaryDirectory() as tmp:
    repo = Path(tmp) / "repo"
    repo.mkdir()
    out = Path(tmp) / "output"
    summary = Path(tmp) / "summary"
    marker = Path(tmp) / "go-invoked"
    bindir = Path(tmp) / "bin"
    bindir.mkdir()
    (bindir / "go").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GO_MARKER"\n')
    (bindir / "go").chmod(0o755)

    def git(*args):
        return subprocess.run(["git", *args], cwd=repo, check=True,
                              capture_output=True).stdout.decode().strip()

    def write(path, body):
        p = repo / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)

    git("init", "-q", "-b", "main")
    git("config", "user.name", "t")
    git("config", "user.email", "t@example.invalid")
    git("config", "commit.gpgsign", "false")
    write(helper, (root / helper).read_text())
    write("README.md", "prose\n")
    git("add", "-A")
    git("commit", "-qm", "I seed the scope fixture", "-s")
    base = git("rev-parse", "HEAD")

    def merge(changes, start=base):
        git("checkout", "-q", "-B", "main", start)
        git("checkout", "-q", "-B", "pr")
        for path, body in changes.items():
            write(path, body)
        git("add", "-A")
        git("commit", "-qm", "I change the scope fixture", "-s")
        git("checkout", "-q", "main")
        git("merge", "-q", "--no-ff", "pr", "-m", "I merge the scope fixture", "--signoff")

    def scope(job, event="pull_request"):
        out.write_text("")
        summary.write_text("")
        env = dict(os.environ, EVENT=event, SCOPE_JOB=job, EXTS="sh yml yaml",
                   RUNNER_TEMP=tmp, GITHUB_OUTPUT=str(out), GITHUB_STEP_SUMMARY=str(summary))
        p = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", scopes[job]["run"]],
                           cwd=repo, env=env, capture_output=True, text=True)
        check(f"scope {job} exits successfully", 0, p.returncode)
        return dict(line.split("=", 1) for line in out.read_text().splitlines()).get("needed", "MISSING")

    def active(step, decision):
        # Narrow model of the expressions used here, not a GitHub runner.
        expr = str(step.get("if", "true")).removeprefix("${{").removesuffix("}} ").removesuffix("}}")
        for key, value in {
            "steps.scope.outputs.needed": repr(decision),
            "steps.actionlint-cache.outputs.cache-hit": "'false'",
            "inputs.check-exec-bit": "True", "inputs.tooling-isolation": "True",
            "true": "True", "false": "False",
        }.items():
            # Only replace identifiers, never quoted 'false' in comparisons.
            if key not in {"true", "false"}:
                expr = expr.replace(key, value)
        expr = expr.replace("&&", " and ").strip()
        if expr == "true":
            return True
        tree = ast.parse(expr, mode="eval")
        allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Compare, ast.NotEq, ast.Eq, ast.Constant)
        if any(not isinstance(n, allowed) for n in ast.walk(tree)):
            raise ValueError(f"unmodelled condition: {expr}")
        return eval(compile(tree, "<step condition>", "eval"), {"__builtins__": {}})

    scopes = {}
    later = {}
    for job, (file, job_id) in specs.items():
        wf = yaml.safe_load((root / ".github/workflows" / file).read_text())
        data = wf["jobs"][job_id]
        check(f"{job} job always reports", False, "if" in data)
        steps = data["steps"]
        i = next((i for i, s in enumerate(steps) if s.get("id") == "scope"), None)
        check(f"{job} has scope step", True, i is not None)
        if i is None:
            continue
        scopes[job] = steps[i]
        later[job] = steps[i + 1:]
        checkout = next(s for s in steps[:i] if "actions/checkout@" in s.get("uses", ""))
        check(f"{job} fetches the merge parent", 2, checkout.get("with", {}).get("fetch-depth"))
    if len(scopes) != 3:
        print(f"DONE lint-job-scope.test.sh {passed} {failed}")
        sys.exit(1)

    for label, changes, wants in [
        ("docs", {"README.md": "changed\n"}, ("false", "false", "false")),
        ("shell", {"new.sh": "echo hi\n"}, ("true", "false", "true")),
        ("workflow", {".github/workflows/w.yml": "jobs: {t: {steps: [{run: 'echo hi'}]}}\n"}, ("true", "true", "true")),
        ("hostile PR helper", {helper: "#!/bin/sh\necho false\n"}, ("true", "true", "true")),
    ]:
        merge(changes)
        for job, want in zip(specs, wants):
            decision = scope(job)
            check(f"{label}: {job} decision", want, decision)
            for step in later[job]:
                check(f"{label}: {job} / {step.get('name', step.get('uses'))}",
                      want == "true", active(step, decision))
            if want == "false":
                check(f"{job} explains the skip", True, "skipped" in summary.read_text())
            if job == "workflow-lint":
                marker.unlink(missing_ok=True)
                install = next(s for s in later[job] if s.get("name") == "Install actionlint")
                if active(install, decision):
                    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                               GO_MARKER=str(marker), ACTIONLINT_VERSION="fixture")
                    subprocess.run(["bash", "-e", "-c", install["run"]], env=env, cwd=repo, check=True)
                check(f"{label}: actionlint compilation invoked", want == "true", marker.exists())

    merge({"README.md": "push prose\n"})
    for job in specs:
        check(f"push always runs {job}", "true", scope(job, "push"))
    # First adoption: the base has no helper. Removing it only from the PR is
    # different: the trusted base classifier must see the deletion and run.
    git("checkout", "-q", "-B", "main", base)
    git("rm", "-q", helper)
    git("commit", "-qm", "I model the pre-adoption base", "-s")
    old_base = git("rev-parse", "HEAD")
    merge({helper: "#!/bin/sh\necho false\n", "README.md": "first adoption\n"}, old_base)
    for job in specs:
        check(f"missing base helper runs {job}", "true", scope(job))

print(f"{passed} passed, {failed} failed")
print(f"DONE lint-job-scope.test.sh {passed} {failed}")
sys.exit(bool(failed))
PY
