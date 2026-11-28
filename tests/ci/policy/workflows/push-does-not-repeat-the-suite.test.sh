#!/usr/bin/env bash
# The suite does not run on a push to main.
#
# What lands on main came through a pull request. The ruleset takes squash merges of a branch
# that is up to date and has passed, with no actor allowed to bypass it, so the tree that lands
# is the tree the pull request tested, and a run on the push spends the minutes of every merge
# to say the same thing. So no workflow with a job that runs suites, a call of the shell
# reusable or a step that runs a file of tests/, has a `push` trigger.
#
# The line limit and the lint of the workflows are not suites: they take seconds, run on the
# push too, and freshness.yml reads their verdicts on main. tests.yml holds the suites, and it
# is named here as well, so a suite moved out of its jobs cannot give it the trigger back.
#
# The checker is shown to refuse each form on planted workflows first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0
HERE = Path(sys.argv[1])
SUITES = "tests.yml"
SUITE_REUSABLE = "reusable-shell-ci.yml"
TESTS_RE = re.compile(r"(^|[\s;&|(])(bash\s+)?\./tests/\S+\.test\.sh")


def triggers(spec):
    on = spec.get("on", spec.get(True)) or {}
    if isinstance(on, str):
        return {on}
    return set(on)


def runs_suites(spec):
    for job in (spec.get("jobs") or {}).values():
        if str(job.get("uses", "")).rsplit("/", 1)[-1].split("@")[0] == SUITE_REUSABLE:
            return True
        for step in job.get("steps") or []:
            if TESTS_RE.search(str(step.get("run", ""))):
                return True
    return False


def problems(folder):
    found = []
    paths = sorted(Path(folder).glob("*.y*ml"))
    for path in paths:
        if path.name.startswith("reusable-"):
            continue
        spec = yaml.safe_load(path.read_text()) or {}
        if "push" in triggers(spec) and (path.name == SUITES or runs_suites(spec)):
            found.append(f"{path.name}: runs suites and has a push trigger, so a merge runs them again")
    if SUITES not in [p.name for p in paths]:
        found.append(f"{SUITES}: is not there, so nothing was held to the rule")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(files):
    with tempfile.TemporaryDirectory() as folder:
        for name, body in files.items():
            (Path(folder) / name).write_text(body)
        return problems(folder)


PR = "on:\n  pull_request:\n"
BOTH = "on:\n  pull_request:\n  push:\n    branches: [main]\n"
CALL = "jobs:\n  shell:\n    uses: ./.github/workflows/reusable-shell-ci.yml\n"
RUN = "jobs:\n  j:\n    runs-on: x\n    steps:\n      - run: ./tests/a/b.test.sh\n"
PLAIN = "jobs:\n  j:\n    runs-on: x\n    steps:\n      - run: echo hi\n"
refused = ": runs suites and has a push trigger, so a merge runs them again"

check("suites on a pull request alone are accepted", [], planted({"tests.yml": PR + CALL}))
check("a push trigger on the suite's workflow is refused", ["tests.yml" + refused],
      planted({"tests.yml": BOTH + CALL}))
check("a push trigger on tests.yml is refused whatever its jobs are", ["tests.yml" + refused],
      planted({"tests.yml": BOTH + PLAIN}))
check("a step that runs a suite on a push is refused in any workflow", ["other.yml" + refused],
      planted({"tests.yml": PR + CALL, "other.yml": BOTH + RUN}))
check("a call of the shell reusable on a push is refused in any workflow", ["other.yml" + refused],
      planted({"tests.yml": PR + CALL, "other.yml": BOTH + CALL}))
check("a push that runs no suite is accepted", [], planted({"tests.yml": PR + CALL, "w.yml": BOTH + PLAIN}))
check("a tree with no tests.yml is not a pass", ["tests.yml: is not there, so nothing was held to the rule"],
      planted({"w.yml": PR + PLAIN}))

check("the workflows of this repository", [], problems(HERE / ".github/workflows"))
total = passed + failed
print(f"passed {passed}, failed {failed}")
print(f"DONE push-does-not-repeat-the-suite.test.sh {passed} {failed}")
sys.exit(0 if failed == 0 and total else 1)
PY
