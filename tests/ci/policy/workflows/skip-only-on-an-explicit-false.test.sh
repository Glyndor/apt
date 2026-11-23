#!/usr/bin/env bash
# A job or step that waits for the answer of a plan skips only when the plan said
# `false`. A condition written `== 'true'` skips on an empty answer too, and the
# answer is empty exactly when the plan job failed or never wrote it: the check it
# decides is then reported as skipped, which GitHub counts as passed.
#
# Two rules over every workflow of the repository:
#
#   * no job or step condition reads the output of a job or a step as `== 'true'`,
#     except the ones listed below with the reason they may;
#   * a job condition that reads the output of another job starts with
#     `!cancelled()`, so the job still starts when the job it waits for failed
#     and does not start in a run that was cancelled.
#
# The checker is shown to refuse each form on planted workflows first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import glob
import os
import re
import sys
import tempfile

import yaml

root = sys.argv[1]
passed = failed = 0
# (workflow file, job) -> why a `== 'true'` is right there: the job is no check a
# merge waits for, and it must not run before what it watches exists.
MAY_WAIT_FOR_A_TRUE = {
    ("freshness.yml", "freshness-published-bytes"):
        "a watcher of published manifests that has nothing to watch before the first publication",
}
TRUE_READ = re.compile(r"\b(?:needs|steps)\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+\s*==\s*['\"]true['\"]")
NEEDS_READ = re.compile(r"\bneeds\.[A-Za-z0-9_-]+\.outputs\b")


def problems(folder):
    found = []
    for path in sorted(glob.glob(os.path.join(folder, "*.y*ml"))):
        name = os.path.basename(path)
        spec = yaml.safe_load(open(path)) or {}
        for job_id, job in (spec.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            conds = [("job", job.get("if"))]
            conds += [("step", s.get("if")) for s in job.get("steps") or [] if isinstance(s, dict)]
            for kind, cond in conds:
                if not isinstance(cond, str):
                    continue
                if TRUE_READ.search(cond) and (name, job_id) not in MAY_WAIT_FOR_A_TRUE:
                    found.append(f"{name}: {kind} of `{job_id}` skips on anything but true: {cond}")
                if kind == "job" and NEEDS_READ.search(cond) and "!cancelled()" not in cond \
                        and (name, job_id) not in MAY_WAIT_FOR_A_TRUE:
                    found.append(f"{name}: job `{job_id}` waits for an output without !cancelled(): {cond}")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(job_yaml):
    with tempfile.TemporaryDirectory() as folder:
        open(os.path.join(folder, "w.yml"), "w").write("jobs:\n  plan: {}\n  suite:\n" + job_yaml)
        return problems(folder)


body = "    runs-on: x\n    needs: plan\n    steps: []\n"
check("a job that waits for the plan with !cancelled() and != 'false' is sound", [],
      planted("    if: ${{ !cancelled() && needs.plan.outputs.run != 'false' }}\n" + body))
check("a job that skips on == 'true' is refused",
      ["w.yml: job of `suite` skips on anything but true: ${{ !cancelled() && needs.plan.outputs.run == 'true' }}"],
      planted("    if: ${{ !cancelled() && needs.plan.outputs.run == 'true' }}\n" + body))
check("a job that waits for an output without !cancelled() is refused",
      ["w.yml: job `suite` waits for an output without !cancelled(): needs.plan.outputs.run != 'false'"],
      planted("    if: needs.plan.outputs.run != 'false'\n" + body))
check("a step that skips on == 'true' is refused",
      ["w.yml: step of `suite` skips on anything but true: steps.scope.outputs.needed == 'true'"],
      planted("    runs-on: x\n    steps:\n      - run: true\n        if: steps.scope.outputs.needed == 'true'\n"))
check("a step that skips only on an explicit false is sound", [],
      planted("    runs-on: x\n    steps:\n      - run: true\n        if: steps.scope.outputs.needed != 'false'\n"))
check("a condition that reads no output is left alone", [],
      planted("    if: github.event_name == 'pull_request'\n" + body))

check("every workflow of this repository skips only on an explicit false", [],
      problems(os.path.join(root, ".github/workflows")))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE skip-only-on-an-explicit-false.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
