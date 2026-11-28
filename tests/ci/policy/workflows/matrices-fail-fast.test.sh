#!/usr/bin/env bash
# A matrix either stops at its first failure or is listed with the reason its
# legs answer for themselves.
#
# A matrix with `fail-fast: false` keeps spending runner minutes on its other
# legs after one of them has already decided the run, and the minutes are the
# most expensive thing this repository spends. A matrix that leaves the setting
# out is the same as one that says false.
#
# The exceptions are the matrices whose legs answer a question of their own, and
# they are listed by (workflow, job) with the reason, in
# tests/ci/policy/workflows/matrix-exceptions.json beside this file. A matrix
# that is not listed says `fail-fast: true`; a listed one says
# `fail-fast: false` and carries its reason. An entry for a matrix that is not
# there is refused, so a reason cannot outlive the matrix it was written for.
#
# The checker is shown to refuse each form on planted workflows first, so a pass
# is shown to be a pass of a check that can fail.
#
# Requires: bash, python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import json
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0
HERE = Path(sys.argv[1])
EXCEPTIONS = "tests/ci/policy/workflows/matrix-exceptions.json"


def load_exceptions(path, folder):
    """The matrices of this repository that answer for themselves.

    Returns ({("workflow", "job"): why}, what is wrong with the file).
    """
    try:
        data = json.loads(path.read_text())
    except OSError as error:
        return {}, [f"the exceptions cannot be read: {type(error).__name__}"]
    except ValueError as error:
        return {}, [f"the exceptions cannot be read: {type(error).__name__}"]
    if not isinstance(data, dict) or sorted(data) != ["independent"] \
            or not isinstance(data["independent"], list):
        return {}, ["the exceptions are not the one list independent"]
    out, found = {}, []
    for entry in data["independent"]:
        if not (isinstance(entry, list) and len(entry) == 3
                and all(isinstance(x, str) and x.strip() for x in entry)):
            found.append("independent: an entry is not [workflow, job, why]")
            continue
        workflow, job, why = entry
        if (workflow, job) in out:
            found.append(f"independent: {workflow} `{job}` is listed twice")
        out[(workflow, job)] = why
        spec = folder / workflow
        jobs = (yaml.safe_load(spec.read_text()) or {}).get("jobs") or {} if spec.is_file() else {}
        if job not in jobs:
            found.append(f"independent: {workflow} has no job `{job}` in this repository, so the entry goes")
    return out, found


def problems(folder, independent):
    """Every matrix that does not stop at its first failure, one line each."""
    found = []
    for path in sorted(Path(folder).glob("*.y*ml")):
        spec = yaml.safe_load(path.read_text()) or {}
        for job_id, job in (spec.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            strategy = job.get("strategy")
            if not isinstance(strategy, dict) or strategy.get("matrix") is None:
                continue
            listed = (path.name, job_id) in independent
            wanted = not listed
            if strategy.get("fail-fast") is not wanted:
                found.append(f"{path.name}: job `{job_id}` has a matrix that does not say fail-fast: {str(wanted).lower()}")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(body, independent=()):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "w.yml").write_text("jobs:\n  j:\n" + body)
        return problems(folder, set(independent))


MATRIX = "    runs-on: ubuntu-26.04\n    strategy:\n      fail-fast: {ff}\n      matrix:\n        a: [1, 2]\n"

check("a matrix that stops at its first failure is accepted", [],
      planted(MATRIX.format(ff="true")))
check("a matrix that does not stop at its first failure is refused",
      ["w.yml: job `j` has a matrix that does not say fail-fast: true"],
      planted(MATRIX.format(ff="false")))
check("a matrix that says nothing is refused",
      ["w.yml: job `j` has a matrix that does not say fail-fast: true"],
      planted("    runs-on: ubuntu-26.04\n    strategy:\n      matrix:\n        a: [1, 2]\n"))
check("a matrix that answers for itself and is listed is accepted", [],
      planted(MATRIX.format(ff="false"), independent=[("w.yml", "j")]))
check("a listed matrix that stops at its first failure is refused",
      ["w.yml: job `j` has a matrix that does not say fail-fast: false"],
      planted(MATRIX.format(ff="true"), independent=[("w.yml", "j")]))
check("a job that is not listed still has to stop at its first failure",
      ["w.yml: job `j` has a matrix that does not say fail-fast: true"],
      planted(MATRIX.format(ff="false")))


def loaded(text, jobs="jobs:\n  j:\n    runs-on: x\n"):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "w.yml").write_text(jobs)
        listed = Path(folder) / "x.json"
        if text is not None:
            listed.write_text(text)
        return load_exceptions(listed, Path(folder))[1]


GOOD = '{"independent": [["w.yml", "j", "why"]]}'
check("an exception that names a job of the repository loads", [], loaded(GOOD))
check("no exceptions file is refused", ["the exceptions cannot be read: FileNotFoundError"], loaded(None))
check("exceptions that are not JSON are refused", ["the exceptions cannot be read: JSONDecodeError"], loaded("{"))
check("a missing list is refused", ["the exceptions are not the one list independent"], loaded("{}"))
check("an entry with no reason is refused", ["independent: an entry is not [workflow, job, why]"],
      loaded('{"independent": [["w.yml", "j", " "]]}'))
check("an entry listed twice is refused", ["independent: w.yml `j` is listed twice"],
      loaded('{"independent": [["w.yml", "j", "a"], ["w.yml", "j", "b"]]}'))
check("an entry for a job that is not here is refused",
      ["independent: w.yml has no job `k` in this repository, so the entry goes"],
      loaded('{"independent": [["w.yml", "k", "why"]]}'))
check("an entry for a workflow that is not here is refused",
      ["independent: z.yml has no job `j` in this repository, so the entry goes"],
      loaded('{"independent": [["z.yml", "j", "why"]]}'))

INDEPENDENT, unreadable = load_exceptions(HERE / EXCEPTIONS, HERE / ".github/workflows")
check("the exceptions of this repository name its own jobs", [], unreadable)
check("every matrix of this repository either stops at its first failure or is listed", [],
      problems(HERE / ".github/workflows", set(INDEPENDENT)))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE matrices-fail-fast.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
