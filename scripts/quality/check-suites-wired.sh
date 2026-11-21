#!/usr/bin/env bash
# Fail when a suite under tests/ is not run by any workflow on a pull request.
#
# tests/ci/suites/ci-runs-every-test.test.sh asserts the same thing, but it
# runs inside the test job whose list it checks. A pull request that drops it
# from the test-command together with other suites leaves the job green: the
# watcher is not run, so it cannot report that it was dropped. This script is
# run by reusable-workflow-lint.yml, a different job and a different check,
# so emptying the test job's list turns that check red instead.
#
# A suite counts as run when a workflow that triggers on every pull request
# (a `pull_request` trigger with no filter) names it in one of two places:
#
#   - the test-command of a job that calls reusable-shell-ci.yml, as one of
#     its whitespace-separated words;
#   - a line of a step's `run:` that starts with `./tests/...test.sh` or
#     `bash ./tests/...test.sh`, and, when that script is the suite runner, the
#     suites the line hands it, in a job and a step that carry no `if:` and
#     no `continue-on-error`. A comment line is prose, not wiring.
#
# In both places the job must carry no `needs:` either. A job whose
# dependency is skipped is skipped too, so `needs:` on a job that GitHub skips
# for an `if: false` switches the suites off one job away, and the skipped
# job still reports Success.
#
# Anything else is a place a pull request can skip, so a suite named only
# there is reported, with the reason it did not count.
#
# A suite that is deliberately not run on pull requests is exempted in
# scripts/quality/suite-exemptions.txt, one per line as
# `tests/<path>.test.sh: <why>`. An exemption without a reason, repeated, or
# for a file that no longer exists is a failure: an exemption that outlived
# its premise is how a hole stays open after the reason for it has gone. One
# for a suite that is run after all has no effect and is reported as a warning,
# because adding an exemption and unwiring its suite take two pull requests.
#
# The pull request does not decide its own exemptions. When
# SUITE_EXEMPTIONS_BASE names the copy of the list taken from the base commit,
# an exemption counts only if it is in both lists: the pull request can remove
# one and the removal applies at once, and one it adds applies from the next
# pull request on, once it is on the base branch. Without SUITE_EXEMPTIONS_BASE
# (a push, or a base that predates the list) the checkout's list applies.
#
# Usage: check-suites-wired.sh [repo-root]   (default: the current directory)
#
# The default is the working directory and not this file's location, because
# the workflow runs the copy of this script taken from the base commit, from
# a temporary file outside the checkout.
set -euo pipefail
root="${1:-$PWD}"
python3 -I - "$root" <<'PY'
import os
import re
import sys

import yaml

root = sys.argv[1]
REUSABLE = "reusable-shell-ci.yml"
WATCHER = "tests/ci/suites/ci-runs-every-test.test.sh"
RUNNER = "tests/ci/suites/check-suite-completeness.test.sh"
SUITE = r"tests/[A-Za-z0-9_./-]+\.test\.sh"
WORD_RE = re.compile(r"^\./(" + SUITE + r")$")
LINE_RE = re.compile(r"^(?:bash\s+)?\./(" + SUITE + r")(?:\s|$)")
ENTRY_RE = re.compile(r"^(" + SUITE + r"):(.*)$")
EXEMPTIONS = "scripts/quality/suite-exemptions.txt"
errors = []


def present():
    found = set()
    for dirpath, _, names in os.walk(os.path.join(root, "tests")):
        for name in names:
            if name.endswith(".test.sh"):
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                found.add(rel.replace(os.sep, "/"))
    return found


def every_pull_request(spec):
    # PyYAML reads the key `on` as the boolean True.
    on = spec.get("on", spec.get(True))
    if on == "pull_request" or (isinstance(on, list) and "pull_request" in on):
        return True
    return isinstance(on, dict) and "pull_request" in on and not on["pull_request"]


def resolve(directory, path):
    return os.path.normpath(os.path.join(directory or ".", path)).replace(os.sep, "/")


def read_workflows():
    directory = os.path.join(root, ".github", "workflows")
    names = sorted(n for n in os.listdir(directory) if n.endswith((".yml", ".yaml"))) \
        if os.path.isdir(directory) else []
    specs = []
    for name in names:
        if name.startswith("reusable-"):
            continue
        try:
            with open(os.path.join(directory, name)) as fh:
                spec = yaml.safe_load(fh)
        except (OSError, yaml.YAMLError) as e:
            errors.append(f"cannot read .github/workflows/{name}: {e}")
            continue
        if not isinstance(spec, dict):
            errors.append(f"cannot read .github/workflows/{name}: not a mapping")
            continue
        specs.append((name, spec))
    if not names:
        errors.append("no workflow under .github/workflows/, so no suite is run")
    return specs


def wiring(specs):
    wired, weak = set(), {}

    def note(path, gate, where):
        # A suite named where a pull request can skip it is kept with the
        # reason, so the failure says why that mention did not count.
        if gate:
            weak.setdefault(path, []).append(f"{where}: {gate}")
        else:
            wired.add(path)

    for name, spec in specs:
        gate = "" if every_pull_request(spec) else \
            "the workflow does not run on every pull request"
        for job_id, job in (spec.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            where = f"{name}#{job_id}"
            job_gate = gate or ("the job has an `if:`" if "if" in job else "") \
                or ("the job has `needs:`, and is skipped when a job it needs is"
                    if "needs" in job else "") \
                or ("the job may fail" if job.get("continue-on-error") else "")
            uses = job.get("uses")
            if isinstance(uses, str) and os.path.basename(uses.split("@")[0]) == REUSABLE:
                with_block = job.get("with") if isinstance(job.get("with"), dict) else {}
                command = with_block.get("test-command")
                for word in str(command or "").split():
                    match = WORD_RE.match(word)
                    if match:
                        note(resolve(with_block.get("working-directory"), match.group(1)),
                             job_gate, where)
                continue
            defaults = ((job.get("defaults") or {}).get("run") or {}).get("working-directory")
            for step in job.get("steps") or []:
                if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                    continue
                step_gate = job_gate or ("the step has an `if:`" if "if" in step else "") \
                    or ("the step may fail" if step.get("continue-on-error") else "")
                here = step.get("working-directory", defaults)
                for line in step["run"].splitlines():
                    match = LINE_RE.match(line.strip())
                    if not match:
                        continue
                    note(resolve(here, match.group(1)), step_gate, where)
                    # The suite runner runs the suites it is handed, as it does in a
                    # test-command, so a line that calls it wires its arguments too.
                    # Only the runner: any other script decides for itself what it
                    # does with an argument, and naming a suite is not running it.
                    if match.group(1) == RUNNER:
                        for word in line.split():
                            more = WORD_RE.match(word)
                            if more:
                                note(resolve(here, more.group(1)), step_gate, where)
    return wired, weak


def read_exemptions(path, label):
    exempt = {}
    try:
        with open(path) as fh:
            text = fh.read()
    except FileNotFoundError:
        return exempt
    except OSError as e:
        errors.append(f"cannot read {label}: {e}")
        return exempt
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = ENTRY_RE.match(line)
        if not match or not match.group(2).strip():
            errors.append(f"{label} line {number} is not `tests/<path>.test.sh: <reason>`: {line}")
        elif match.group(1) in exempt:
            errors.append(f"{label} line {number} repeats {match.group(1)}")
        else:
            exempt[match.group(1)] = match.group(2).strip()
    return exempt


def exemptions():
    exempt = read_exemptions(os.path.join(root, EXEMPTIONS), EXEMPTIONS)
    base_path = os.environ.get("SUITE_EXEMPTIONS_BASE", "")
    if not base_path:
        return exempt
    if not os.path.isfile(base_path):
        errors.append(f"cannot read the base copy of {EXEMPTIONS} at {base_path}")
        return {}
    base = read_exemptions(base_path, f"{EXEMPTIONS} on the base commit")
    for path in sorted(set(exempt) - set(base)):
        print(f"pending: {path} is exempt once this list is on the base branch, not before")
    return {path: why for path, why in exempt.items() if path in base}


suites = present()
specs = read_workflows()
wired, weak = wiring(specs)
exempt = exemptions()
if not suites:
    errors.append("no tests/**/*.test.sh found, so this check would pass having looked at nothing")
for path in sorted(exempt):
    if path not in suites:
        errors.append(f"the exemption for {path} names a file that does not exist; delete it")
    elif path in wired:
        print(f"::warning::{path} is exempt but a workflow runs it, so the exemption has no effect")
for path in sorted(suites - wired - set(exempt)):
    why = "; ".join(weak.get(path, [])) or "it is named nowhere"
    errors.append(f"{path} is not run by any workflow on a pull request ({why})")
if WATCHER in suites and WATCHER not in wired and WATCHER not in exempt:
    errors.append(f"{WATCHER}, the watcher inside the test job, is itself not run, "
                  "so nothing inside that job can report a dropped suite")
for message in errors:
    print(f"::error::{message}")
if errors:
    sys.exit(1)
for path in sorted(exempt):
    print(f"exempt: {path}: {exempt[path]}")
print(f"{len(wired & suites)} suite(s) under tests/ are run by a workflow on every pull request, "
      f"{len(exempt)} exempt.")
PY
