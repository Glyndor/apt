#!/usr/bin/env bash
# The `ML-DSA-65 verifier` job of tests.yml decides whether it has anything to
# look at, and still reports under its own name. Both halves have to hold:
#
#   * a job that is skipped as a job reports success, so if the owner makes
#     the check required, a skip by `if:`, `needs:` or a path filter would turn
#     "did not apply" into "passed" with no way to tell the two apart. The job
#     therefore always starts and reports; only its steps are conditional;
#   * the decision has to be read from the commit the change is measured
#     against, fail open to "run", and ask for a push as well as a pull request.
#
# The shape is checked on the workflow as it ships, and on planted copies that
# break one property each, so a pass is the pass of a check that can fail. The
# decision step is then executed over real git (the merge commit of a pull
# request, the single commit a push leaves), with the repository's own resolver
# and map, and so is the step that runs the suite.
#
# Requires: bash, git, python3 with PyYAML (the test job installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import copy
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

root = Path(sys.argv[1])
passed = failed = 0
CHECK_NAME = "ML-DSA-65 verifier"
RESOLVER = "scripts/quality/scope/ci-job-scope.sh"
MAP = "scripts/quality/scope/suite-scope.txt"
RUNNER = "tests/ci/suites/check-suite-completeness.test.sh"
NEEDED = "steps.scope.outputs.needed != 'false'"
CANCEL = "${{ github.event_name == 'pull_request' }}"


def check(name, want, got):
    global passed, failed
    if want == got:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}: expected {want!r}, got {got!r}")


def audit(spec, map_text=None):
    """One line per way the job can stop reporting, or stop deciding."""
    found = []
    on = spec.get("on", spec.get(True))
    for event in ("pull_request", "push"):
        if isinstance(on, dict) and isinstance(on.get(event), dict) and (
                "paths" in on[event] or "paths-ignore" in on[event]):
            found.append(f"a path filter on {event} leaves the check unreported")
    job = (spec.get("jobs") or {}).get("mldsa")
    if not isinstance(job, dict):
        return found + ["there is no job mldsa"]
    if job.get("name") != CHECK_NAME:
        found.append(f"the check is named {job.get('name')!r}, not {CHECK_NAME!r}")
    for key in ("if", "needs", "continue-on-error", "uses"):
        if key in job:
            found.append(f"the job has `{key}:`, so it can be skipped or can fail without failing")
    group = job.get("concurrency") or spec.get("concurrency") or {}
    if not isinstance(group, dict) or group.get("cancel-in-progress") != CANCEL:
        found.append("concurrency does not cancel on a pull request only")
    elif "github.ref" not in str(group.get("group")) or not re.search(
            r"github\.run_id|github\.event_name", str(group.get("group"))):
        found.append("the concurrency group does not tell a pull request from a push")
    steps = job.get("steps") or []
    ids = [s.get("id") for s in steps]
    if "scope" not in ids:
        return found + ["there is no decision step with id `scope`"]
    at = ids.index("scope")
    checkout = steps[0] if steps else {}
    if "actions/checkout@" not in str(checkout.get("uses")) or (checkout.get("with") or {}).get("fetch-depth") != 2:
        found.append("the first step is not a checkout of two commits, so HEAD^1 and the commit a push replaced are not there")
    scope = steps[at]
    run, env = str(scope.get("run", "")), scope.get("env") or {}
    suite = env.get("SUITE", "")
    if "if" in scope:
        found.append("the decision step is conditional")
    if env.get("EVENT") != "${{ github.event_name }}" or env.get("BEFORE_SHA") != "${{ github.event.before }}":
        found.append("the decision does not read the event and the commit a push replaced")
    if RESOLVER not in run or "suite-needed" not in run:
        found.append("the decision step does not ask the resolver for suite-needed")
    if not suite or not (root / suite).is_file():
        found.append(f"the suite the decision names does not exist: {suite!r}")
    runners = [s for s in steps if RUNNER + " ./" + suite in str(s.get("run", ""))]
    if len(runners) != 1:
        found.append("the suite is not run by exactly one step through the runner")
    for step in steps[at + 1:]:
        if step in runners:
            if "if" in step or "continue-on-error" in step:
                found.append("the step that runs the suite is conditional, which the wiring check does not count")
            if (step.get("env") or {}).get("NEEDED") != "${{ steps.scope.outputs.needed }}" or \
                    not re.search(r'\[ "\$NEEDED" = false \]', str(step.get("run"))):
                found.append("the step that runs the suite does not read the decision")
        elif str(step.get("if", "")).strip() != NEEDED:
            found.append(f"the step {step.get('name')!r} does not wait for the decision")
    entry = scope_entry(suite, map_text)
    if entry is None:
        found.append(f"{MAP} has no entry for {suite}")
    else:
        wheel = [m for s in steps for m in re.findall(r"-r (\S+)", str(s.get("run", "")))]
        for needed in [".github/workflows/tests.yml", suite, *wheel]:
            if not any(p == needed or (p.endswith("/**") and needed.startswith(p[:-2])) for p in entry):
                found.append(f"the entry for {suite} does not cover {needed}")
    return found


def scope_entry(suite, text=None):
    patterns, current = None, None
    for raw in (text if text is not None else (root / MAP).read_text()).splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[:1].isspace():
            current = raw.strip()
            if current == suite:
                patterns = []
        elif current == suite:
            patterns.append(raw.strip())
    return patterns


spec = yaml.safe_load((root / ".github/workflows/tests.yml").read_text())
check("the job as it ships has none of the ways to stop reporting or deciding", [], audit(spec))

job = spec["jobs"]["mldsa"]
suite = next(s for s in job["steps"] if s.get("id") == "scope")["env"]["SUITE"]
entry = scope_entry(suite)


def broken(mutate):
    clone = copy.deepcopy(spec)
    mutate(clone)
    return audit(clone)


def step(clone, name):
    return next(s for s in clone["jobs"]["mldsa"]["steps"] if s.get("name", "").startswith(name))


for label, mutate, fragment in [
    ("an `if:` on the job", lambda c: c["jobs"]["mldsa"].update({"if": "github.event_name == 'push'"}), "the job has `if:`"),
    ("a `needs:` on the job", lambda c: c["jobs"]["mldsa"].update({"needs": ["shell"]}), "the job has `needs:`"),
    ("continue-on-error on the job", lambda c: c["jobs"]["mldsa"].update({"continue-on-error": True}), "the job has `continue-on-error:`"),
    ("a renamed check", lambda c: c["jobs"]["mldsa"].update({"name": "ML-DSA verifier"}), "the check is named"),
    ("a path filter on the pull request", lambda c: c[True].update({"pull_request": {"paths": ["scripts/**"]}}), "a path filter on pull_request"),
    ("a path filter on the push", lambda c: c[True]["push"].update({"paths-ignore": ["docs/**"]}), "a path filter on push"),
    ("a concurrency that always cancels", lambda c: c["jobs"]["mldsa"].update({"concurrency": {"group": "g-${{ github.ref }}", "cancel-in-progress": True}}), "does not cancel on a pull request only"),
    ("a concurrency group shared by a pull request and a push", lambda c: c["jobs"]["mldsa"].update({"concurrency": {"group": "g-${{ github.ref }}", "cancel-in-progress": CANCEL}}), "does not tell a pull request from a push"),
    ("a shallow checkout", lambda c: c["jobs"]["mldsa"]["steps"][0]["with"].update({"fetch-depth": 1}), "not a checkout of two commits"),
    ("a decision that does not ask the resolver", lambda c: step(c, "Decide").update({"run": "echo needed=false >> \"$GITHUB_OUTPUT\""}), "does not ask the resolver"),
    ("a conditional decision", lambda c: step(c, "Decide").update({"if": "false"}), "the decision step is conditional"),
    ("a decision blind to a push", lambda c: step(c, "Decide")["env"].pop("BEFORE_SHA"), "the commit a push replaced"),
    ("an install that ignores the decision", lambda c: step(c, "Install").pop("if"), "does not wait for the decision"),
    ("a suite step with an `if:`", lambda c: step(c, "Run").update({"if": NEEDED}), "the step that runs the suite is conditional"),
    ("a suite step that ignores the decision", lambda c: step(c, "Run").pop("env"), "does not read the decision"),
    ("a suite no step runs", lambda c: step(c, "Run").update({"run": "true"}), "not run by exactly one step"),
]:
    check(f"planted: {label} is reported", True, any(fragment in line for line in broken(mutate)))

check("planted: an entry that omits the wheel's requirements file is reported", True, any(
    "does not cover" in line for line in audit(spec, f"{suite}\n\t{suite}\n\t.github/workflows/tests.yml\n")))
check("planted: a map with no entry for the suite is reported", True, any(
    "has no entry" in line for line in audit(spec, "tests/other.test.sh\n\tscripts/**\n")))

# --- the decision step, over real git -------------------------------------------

scope_run = next(s for s in job["steps"] if s.get("id") == "scope")["run"]
suite_run = next(s for s in job["steps"] if s.get("name", "").startswith("Run"))["run"]
inside = []
for pattern in entry:
    base = pattern[:-3] if pattern.endswith("/**") else pattern
    inside.append(base + "/zz-touched.txt" if pattern.endswith("/**") else base)
outside = ["README.md", "docs/zz-prose.md"]

tmp = tempfile.TemporaryDirectory()
work = Path(tmp.name)


def git(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True).stdout.strip()


def write(repo, path, body):
    p = repo / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body)


def fixture(name, resolver=None):
    repo = work / name
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "t")
    git(repo, "config", "user.email", "t@example.invalid")
    git(repo, "config", "commit.gpgsign", "false")
    write(repo, RESOLVER, resolver if resolver is not None else (root / RESOLVER).read_text())
    write(repo, MAP, (root / MAP).read_text())
    write(repo, RUNNER, "#!/bin/sh\necho ran >> \"$MARKER\"\n")
    (repo / RUNNER).chmod(0o755)
    write(repo, "README.md", "prose\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")
    return repo


def change(repo, paths, how, extra=None):
    """Commit `paths` as a pull request (a merge commit) or as a push (one commit)."""
    before = git(repo, "rev-parse", "HEAD")
    if how == "pr":
        git(repo, "checkout", "-q", "-b", "pr")
    for path in paths:
        write(repo, path, "changed\n")
    for path, body in (extra or {}).items():
        write(repo, path, body)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "change")
    if how == "pr":
        git(repo, "checkout", "-q", "main")
        git(repo, "merge", "-q", "--no-ff", "pr", "-m", "merge")
    return before


def decide(repo, event, before="", script=scope_run):
    out, summary = work / "output", work / "summary"
    out.write_text("")
    summary.write_text("")
    env = dict(os.environ, EVENT=event, BEFORE_SHA=before, SUITE=suite, RUNNER_TEMP=str(work),
               GITHUB_OUTPUT=str(out), GITHUB_STEP_SUMMARY=str(summary))
    done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=repo, env=env,
                          capture_output=True, text=True)
    needed = dict(line.split("=", 1) for line in out.read_text().splitlines()).get("needed", "MISSING")
    return done.returncode, needed, summary.read_text()


n = 0


def case(label, how, paths, want, event=None, before_of=None, **fixture_args):
    global n
    n += 1
    repo = fixture(f"case{n}", **fixture_args)
    before = change(repo, paths, how)
    event = event or ("pull_request" if how == "pr" else "push")
    rc, needed, summary = decide(repo, event, before if how == "push" else "")
    check(f"{label}: the step succeeds", 0, rc)
    check(f"{label}: needed", want, needed)
    return summary


summary = case("a pull request that changes prose", "pr", outside, "false")
check("a skip by decision says so in the step summary", True, "skipped by decision" in summary)
for path in inside:
    case(f"a pull request that changes {path}", "pr", [path], "true")
case("a pull request that changes prose and an input", "pr", [outside[0], inside[0]], "true")
case("a push that changes prose", "push", outside, "false")
for path in inside:
    case(f"a push that changes {path}", "push", [path], "true")

hostile = "#!/usr/bin/env bash\necho false\n"
repo = fixture("hostile")
change(repo, [inside[0]], "pr", extra={RESOLVER: hostile})
check("a pull request that rewrites the resolver is judged by the base's", "true", decide(repo, "pull_request")[1])
repo = fixture("narrow")
change(repo, [inside[0]], "pr", extra={MAP: f"{suite}\n\tnothing/**\n"})
check("a pull request that narrows its own entry is judged by the base's", "true", decide(repo, "pull_request")[1])

repo = fixture("noresolver", resolver="")
git(repo, "rm", "-q", RESOLVER)
git(repo, "commit", "-qm", "no resolver")
change(repo, outside, "pr")
check("a base without the resolver runs the suite", "true", decide(repo, "pull_request")[1])
for label, body in [("a resolver that fails", "#!/usr/bin/env bash\nexit 1\n"),
                    ("a resolver that prints nothing", "#!/usr/bin/env bash\nexit 0\n"),
                    ("a resolver that prints something else", "#!/usr/bin/env bash\necho maybe\n")]:
    repo = fixture(label.replace(" ", "-"), resolver=body)
    change(repo, outside, "pr")
    rc, needed, _ = decide(repo, "pull_request")
    check(f"{label}: the step succeeds", 0, rc)
    check(f"{label}: the suite runs", "true", needed)

repo = fixture("schedule")
change(repo, outside, "push")
check("a schedule runs the suite", "true", decide(repo, "schedule")[1])
check("a manual dispatch runs the suite", "true", decide(repo, "workflow_dispatch")[1])
for label, before in [("an empty", ""), ("an all-zero", "0" * 40), ("a wrong", "1" * 40), ("a malformed", "HEAD^1")]:
    check(f"a push with {label} before runs the suite", "true", decide(repo, "push", before)[1])

# The control: a decision step that reads the resolver from the checkout instead
# of the base lets the pull request that rewrites it skip itself.
repo = fixture("control")
change(repo, [inside[0]], "pr", extra={RESOLVER: hostile})
weak = re.sub(r'git show "\$base:' + re.escape(RESOLVER) + r'"', "cat " + RESOLVER, scope_run)
check("the control changed the step", True, weak != scope_run)
check("control: a step that reads the checkout's resolver is skipped by it", "false", decide(repo, "pull_request", script=weak)[1])

# --- the step that runs the suite -------------------------------------------------

marker = work / "marker"
for label, needed, ran in [("false", "false", False), ("true", "true", True), ("an empty decision", "", True),
                            ("a decision that is not a boolean", "maybe", True)]:
    repo = fixture("run-" + str(len(label)) + needed)
    marker.unlink(missing_ok=True)
    done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", suite_run], cwd=repo, capture_output=True, text=True,
                          env=dict(os.environ, NEEDED=needed, MARKER=str(marker)))
    check(f"the run step with {label}: exits 0", 0, done.returncode)
    check(f"the run step with {label}: the suite {'runs' if ran else 'does not run'}", ran, marker.exists())
    if not ran:
        check("and says it was skipped by decision", True, "skipped by decision" in done.stdout)

print(f"{passed} passed, {failed} failed")
print(f"DONE mldsa-job-scope.test.sh {passed} {failed}")
sys.exit(bool(failed))
PY
