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
# A `run:` line counts only when nothing follows the invocation but its
# arguments: no `|`, `&`, `;`, redirection, backtick or `$(`, and no
# continuation onto the next line. `|| true`, `&& :`, a pipe without
# pipefail or a background `&` keep the suite running and throw its verdict
# away. A step whose `run:` holds a here-doc wires nothing, because a path in
# it may be data that never runs; neither does one that turns errexit off
# (`set +e`) or runs under a `shell:` other than bash.
#
# What this cannot decide: a line in a branch that is never taken
# (`if false; then`), after an unconditional `exit`, or in a function that is
# never called still counts. Telling those apart needs the shell's own
# reading of the script, and a check that pretended to have it would be
# worse than one that says where it stops.
#
# A caller of reusable-shell-ci.yml may list `skip-suite-paths`: a pull
# request whose changed files all match them skips the whole suite, and the
# job still reports green. tests/ci/suites/shell-ci-scope.test.sh holds the
# list to files the suite does not read, but it runs inside that job, so a
# pull request that widens the list to `*` skips the suite that would have
# refused it. A pull request that widens the list changes the workflow that
# carries it, so the suites of a caller count only when no pattern matches a
# file under .github/, scripts/ or tests/: then the change that widens the
# list is never one the list skips, and its own run judges it. The match is
# made by bash, with the same loop as the reusable's scope step, because a
# second grammar (fnmatch reads `[^x]` and `@(a|b)` differently) would let a
# pattern skip the suite while the check read it as matching nothing.
#
# In both places the job may carry `needs:` only on jobs GitHub never skips. A
# job whose dependency is skipped is skipped too, so `needs:` on a job that GitHub
# skips for an `if: false` switches the suites off one job away, and the skipped
# job still reports Success. A dependency counts as one that is never skipped when
# it is a job of the same workflow with no `if:` and no `continue-on-error:`, and
# its own `needs:` pass this test in turn: it can then only fail or be cancelled,
# and the pull request is red for that reason. A name that is not a job of the
# workflow, or a cycle, does not count.
#
# Anything else is a place a pull request can skip, so a suite named only
# there is reported, with the reason it did not count.
#
# A suite that is deliberately not run on pull requests is exempted in
# scripts/quality/coverage/suite-exemptions.txt, one per line as
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
import json
import os
import re
import subprocess
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
OPERATOR_RE = re.compile(r"[|&;<>`]|\$\(")
ERREXIT_OFF_RE = re.compile(r"\bset\s+\+[A-Za-z]*e|\bset\s+\+o\s+errexit")
EXEMPTIONS = "scripts/quality/coverage/suite-exemptions.txt"
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


def never_skipped():
    # The files a skip pattern must not match.
    found = []
    for top in (".github", "scripts", "tests"):
        for dirpath, _, names in os.walk(os.path.join(root, top)):
            found += [os.path.relpath(os.path.join(dirpath, n), root).replace(os.sep, "/")
                      for n in names]
    return sorted(found)


# The reusable's own matching loop: `set -f`, the list split by the shell on
# whitespace, and `[[ "$f" == $pattern ]]`, where bash reads the pattern with
# extglob on and `*` crosses a `/`. The list arrives in the environment and
# the paths on stdin, never in the text of the script, and the first match is
# printed as pattern NUL path.
SKIP_MATCH = r"""
set -f
while IFS= read -r -d '' f; do
  for pattern in $SKIP_PATHS; do
    if [[ "$f" == $pattern ]]; then printf '%s\0%s' "$pattern" "$f"; exit 0; fi
  done
done
"""


def skipped_by(patterns, files):
    if not patterns.split():
        return None
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "SKIP_PATHS": patterns}
    done = subprocess.run(["bash", "--noprofile", "--norc", "-c", SKIP_MATCH], env=env,
                          input="".join(f + "\0" for f in files).encode(),
                          stdout=subprocess.PIPE, check=True)
    return tuple(done.stdout.decode().split("\0", 1)) if done.stdout else None


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


def reusable_gate(uses, only_pr=False):
    """Why a job that calls this workflow can be skipped, or "" when it cannot: the
    workflow is a local reusable, it reads, and none of its jobs has an `if:` or may
    fail. An external one is never read, so it is refused. `if: github.event_name ==
    'pull_request'` is no condition in a workflow that runs on pull requests and nothing else."""
    match = re.fullmatch(r"\./\.github/workflows/(reusable-[A-Za-z0-9_.-]+\.ya?ml)", uses.split("@")[0])
    if not match:
        return f"it calls `{uses}`, which is not a local reusable workflow and is not read"
    try:
        with open(os.path.join(root, ".github", "workflows", match.group(1))) as fh:
            inner = (yaml.safe_load(fh) or {}).get("jobs") or {}
    except (OSError, yaml.YAMLError, AttributeError):
        return f"it calls `{uses}`, which cannot be read"
    for inner_id, inner_job in inner.items():
        only = only_pr and inner_job.get("if") == "github.event_name == 'pull_request'" if isinstance(inner_job, dict) else False
        if not isinstance(inner_job, dict) or ("if" in inner_job and not only) or inner_job.get("continue-on-error"):
            return f"it calls `{uses}`, whose job `{inner_id}` carries a condition and can be skipped"
    return ""


def base_gate(name):
    """The `gate` job of the workflow in the base commit the event names (BASE_SHA); False when that
    commit holds no gate (or no such workflow); None when no base is named and this is not a pull
    request; a string, the reason, when a base is expected or named and cannot be read."""
    base = os.environ.get("BASE_SHA", "")
    if not base:
        if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
            return "BASE_SHA is empty in a pull request, so the `gate` job cannot be compared with the base commit's"
        print("no BASE_SHA is named: the `gate` job is not compared with a base commit")
        return None
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        return f"BASE_SHA {base!r} is not a commit id, so the `gate` job cannot be compared with the base commit's"
    git = ["git", "-C", root]
    if subprocess.run([*git, "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True, check=False).returncode:
        return f"the base commit {base} cannot be read, so the `gate` job cannot be compared with its copy"
    if subprocess.run([*git, "cat-file", "-e", f"{base}:.github/workflows/{name}"], capture_output=True, check=False).returncode:
        return False
    try:
        text = subprocess.run([*git, "show", f"{base}:.github/workflows/{name}"], capture_output=True, check=True).stdout
        gate = ((yaml.safe_load(text) or {}).get("jobs") or {}).get("gate")
    except (OSError, subprocess.CalledProcessError, yaml.YAMLError, AttributeError):
        return False
    return gate if isinstance(gate, dict) else False


def every_dependency(job, jobs, found=None):
    """The names of every job this one waits for, directly or through others."""
    found = set() if found is None else found
    for name_ in job["needs"] if isinstance(job.get("needs"), list) else [job.get("needs")] if job.get("needs") else []:
        if isinstance(name_, str) and name_ not in found:
            found.add(name_)
            if isinstance(jobs.get(name_), dict):
                every_dependency(jobs[name_], jobs, found)
    return found


# What the `gate` job and the job that waits may carry. A property the contract does not know can change what
# runs without changing the text the other checks read (`shell`, `defaults`, `continue-on-error`), so it is refused.
GATE_JOB_KEYS = {"name", "needs", "if", "runs-on", "timeout-minutes", "permissions", "steps"}
GATE_STEP_KEYS = {"name", "env", "run"}
WAITER_KEYS = {"name", "needs", "uses", "with", "secrets", "permissions", "runs-on", "timeout-minutes", "steps"}
workflow_defaults = False


def unknown_properties(gate, waiter):
    """The first property of the gate, its steps or the job that waits that the contract does not list, or ""."""
    found = [("the `gate` job", k) for k in gate if k not in GATE_JOB_KEYS]
    found += [("a step of the `gate` job", k) for st in gate.get("steps") or [] for k in (st if isinstance(st, dict) else {"": 0}) if k not in GATE_STEP_KEYS]
    found += [("the job that waits", k) for k in waiter if k not in WAITER_KEYS]
    if workflow_defaults:
        found.append(("the workflow", "defaults"))
    return f"{found[0][0]} carries `{found[0][1]}`, which the contract does not know" if found else ""


def gate_answers(job_id, jobs, name):
    """Why nothing answers for this job when a job it needs fails, or "" when a gate does.

    A job whose dependency fails is skipped, and a skipped job reports Success, so
    `needs:` is accepted only beside a `gate` job in the same workflow that runs whatever
    happened (`if: always()`), may not fail without failing the run, needs this job and
    every job it waits for (a job that carries no condition can still fail), reads each of
    their results and fails on anything but success. The gate is the one the base commit
    holds: a pull request that changes it, or brings it, is not judged by itself."""
    gate = jobs.get("gate")
    if not isinstance(gate, dict) or gate.get("if") != "always()" or gate.get("continue-on-error"):
        return "no `gate` job with `if: always()` answers for it"
    odd = unknown_properties(gate, jobs[job_id])
    if odd:
        return odd
    wait = gate.get("needs") if isinstance(gate.get("needs"), list) else [gate.get("needs")]
    steps = [x for x in gate.get("steps") or [] if isinstance(x, dict)]
    owed = every_dependency(jobs[job_id], jobs) | {job_id}
    seen = [str(v) for st in steps for v in (st.get("env") or {}).values()]
    reads = all(any(f"needs.{x}.result" in v or "toJSON(needs)" in v for v in seen) for x in owed)
    fails = any("success" in str(st.get("run", "")) and ("exit 1" in str(st.get("run", "")) or "sys.exit(" in str(st.get("run", ""))) for st in steps)
    if not owed <= set(wait) or not reads or not fails:
        return f"the `gate` job does not need `{job_id}` and every job it waits for, read their results and fail on anything but success"
    before = base_gate(name)
    if isinstance(before, str):
        return before
    if before is False:
        return "the `gate` job is not in the base commit, which cannot vouch for it"
    if before is not None and json.dumps(before, sort_keys=True) != json.dumps(gate, sort_keys=True):
        return "the `gate` job differs from the base commit's, and it is what answers for the job"
    return ""


def needs_gate(job, jobs, seen=(), job_id="", name="", only_pr=False):
    """Why `needs:` on this job can skip it, or "" when it cannot.

    A job whose dependency is skipped is skipped too, and a skipped job reports
    Success. So `needs:` is a way to switch the suites off one job away, unless
    every job it names is one GitHub never skips (a job of the same workflow with
    no `if:`, no `continue-on-error`, no `uses:` of a workflow that is not a local
    reusable whose jobs are all unconditional, and `needs:` that pass this test in
    turn) and a gate answers for it. A name that is not a job of the workflow, a
    condition anywhere on the chain and a cycle are all refused."""
    if "needs" not in job:
        return ""
    names = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
    base = "the job has `needs:`, and is skipped when a job it needs is"
    for name_ in names:
        other = jobs.get(name_) if isinstance(name_, str) else None
        if not isinstance(other, dict):
            return f"{base}; `{name_}` is not a job of this workflow"
        if name_ in seen:
            return f"{base}; `{name_}` needs itself"
        if "if" in other or other.get("continue-on-error") or "defaults" in other:
            return f"{base}; `{name_}` carries a condition and can be skipped"
        if isinstance(other.get("uses"), str):
            why = reusable_gate(other["uses"], only_pr)
            if why:
                return f"{base}; `{name_}`: {why}"
        deeper = needs_gate(other, jobs, seen + (name_,), job_id, name, only_pr)
        if deeper:
            return deeper
    if not seen:
        answer = gate_answers(job_id, jobs, name)
        if answer:
            return f"{base} and {answer}"
    return ""


def pr_only(spec):
    """True when the workflow runs on pull requests and on nothing else."""
    events = spec.get("on", spec.get(True))
    return (set(events) if isinstance(events, (dict, list)) else {events}) == {"pull_request"}


def wiring(specs):
    global workflow_defaults
    wired, weak = set(), {}
    guarded = never_skipped()

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
        workflow_shell = ((spec.get("defaults") or {}).get("run") or {}).get("shell")
        workflow_defaults = bool(spec.get("defaults"))
        jobs = spec.get("jobs") or {}
        for job_id, job in jobs.items():
            if not isinstance(job, dict):
                continue
            where = f"{name}#{job_id}"
            job_gate = gate or ("the job has an `if:`" if "if" in job else "") \
                or needs_gate(job, jobs, (), job_id, name, pr_only(spec)) \
                or ("the job may fail" if job.get("continue-on-error") else "")
            uses = job.get("uses")
            if isinstance(uses, str) and os.path.basename(uses.split("@")[0]) == REUSABLE:
                with_block = job.get("with") if isinstance(job.get("with"), dict) else {}
                command = with_block.get("test-command")
                hit = skipped_by(str(with_block.get("skip-suite-paths") or ""), guarded)
                skip_gate = job_gate or (
                    f"its skip-suite-paths `{hit[0]}` matches {hit[1]}, so a pull request that "
                    "changes only such files, this list included, skips every suite" if hit else "")
                for word in str(command or "").split():
                    match = WORD_RE.match(word)
                    if match:
                        note(resolve(with_block.get("working-directory"), match.group(1)),
                             skip_gate, where)
                continue
            defaults = (job.get("defaults") or {}).get("run") or {}
            shell_default = defaults.get("shell", workflow_shell)
            for step in job.get("steps") or []:
                if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                    continue
                run, shell = step["run"], step.get("shell", shell_default)
                step_gate = job_gate or ("the step has an `if:`" if "if" in step else "") \
                    or ("the step may fail" if step.get("continue-on-error") else "") \
                    or (f"the step runs under `shell: {shell}`" if shell not in (None, "bash") else "") \
                    or ("the step's run: holds a here-doc, so a path in it may be data"
                        if "<<" in run else "") \
                    or ("the step turns errexit off" if ERREXIT_OFF_RE.search(run) else "")
                here = step.get("working-directory", defaults.get("working-directory"))
                for line in run.splitlines():
                    match = LINE_RE.match(line.strip())
                    if not match:
                        continue
                    rest = line.strip()[match.end():]
                    if not step_gate and (OPERATOR_RE.search(rest) or line.rstrip().endswith("\\")):
                        note(resolve(here, match.group(1)),
                             "the line goes on with a shell operator, which can discard "
                             "the suite's verdict", where)
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
