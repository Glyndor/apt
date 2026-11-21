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
helper = "scripts/quality/scope/ci-job-scope.sh"
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
    marker = Path(tmp) / "download-invoked"
    bindir = Path(tmp) / "bin"
    bindir.mkdir()
    # The install downloads the release tarball; a stub curl records the call
    # and fails, so nothing is fetched and the step stops there.
    (bindir / "curl").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOWNLOAD_MARKER"\nexit 22\n')
    (bindir / "curl").chmod(0o755)

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
                               DOWNLOAD_MARKER=str(marker), ACTIONLINT_VERSION="v0.0.0",
                               ACTIONLINT_SHA256="0" * 64, RUNNER_TEMP=tmp,
                               GITHUB_PATH=str(Path(tmp) / "path"))
                    subprocess.run(["bash", "-e", "-c", install["run"]], env=env, cwd=repo)
                check(f"{label}: actionlint download invoked", want == "true", marker.exists())

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

    # The pull request that moves the helper into its folder: the base carries
    # it at the path it had before, so the new path is not in the base and the
    # scope cannot be established. Every job runs, which is the fail-open
    # answer, and nothing is skipped on the strength of the pull request's copy:
    # the one it moves is hostile here, and would say false if it were asked.
    # Once a move is merged the next pull request reads the helper from the base
    # again and skips what it can.
    legacy = "scripts/quality/ci-job-scope.sh"
    body = (root / helper).read_text()

    def moved(new_body):
        git("checkout", "-q", "-B", "main", base)
        git("rm", "-q", helper)
        write(legacy, body)
        git("add", "-A")
        git("commit", "-qm", "I model the base before the helper moved", "-s")
        git("checkout", "-q", "-B", "pr")
        git("rm", "-q", legacy)
        write(helper, new_body)
        write("README.md", "the helper moves\n")
        git("add", "-A")
        git("commit", "-qm", "I move the helper", "-s")
        git("checkout", "-q", "main")
        git("merge", "-q", "--no-ff", "pr", "-m", "I merge the move", "--signoff")

    moved("#!/bin/sh\necho false\n")
    for job in specs:
        check(f"a base with the helper at its old path runs {job}", "true", scope(job))
    moved(body)
    for job in specs:
        check(f"the move of the real helper runs {job}", "true", scope(job))
    after_move = git("rev-parse", "HEAD")
    merge({"README.md": "prose after the move\n"}, after_move)
    for job in specs:
        check(f"the pull request after the move reads the helper from the base: {job}", "false", scope(job))

print(f"{passed} passed, {failed} failed")
print(f"DONE lint-job-scope.test.sh {passed} {failed}")
sys.exit(bool(failed))
PY
