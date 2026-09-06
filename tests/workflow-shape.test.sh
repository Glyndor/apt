#!/usr/bin/env bash
# Guard two workflow properties that nothing else checks.
#
# A. Each required status check on main is named `<job id> / <job name>`. The
#    file is not part of the name. Rename either half and the emitted check
#    name changes, the ruleset still wants the old one, and every pull request
#    sits BLOCKED with nothing saying why. The list below mirrors the ruleset
#    and has to be updated with it: changing one without the other would put
#    this test in the same trap it exists to close, so they are paired.
#
# B. .github/workflows/drift.yml runs on schedule and workflow_dispatch, and
#    on nothing else. The header explains why: pull_request would deadlock
#    three channels (the first repository's pull request goes red on the
#    others still carrying the old copy), and push: main reads its siblings
#    from a CDN that serves the previous file for several minutes after a
#    merge. The schedule sidesteps both rather than handling either.
#    Re-adding either trigger is a two-word edit no test reads, and that is
#    the gap this file closes.
#
# Both rules are absence checks. A checker that returns nothing on a planted
# violation is the failure mode here, so the cases below plant one and require
# it to be named. `diff -q` confirms each plant actually changed the file
# before the result is read; otherwise the violation could not exist in the
# fixture and the case would pass for the wrong reason.
#
# Requires: python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$HERE/.github/workflows"

pass=0
fail=0

check() { # $1=description  $2=expected  $3=actual
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Walk every workflow in the given directory and report each required check
# whose emitted name would no longer match. For a caller (the only shape in
# this repository) the emitted name is `<caller job id> / <inner job name>`,
# so the check walks callers, follows the `uses:` pointer to a reusable, and
# looks for an inner job whose `name:` matches the second half. A direct job
# whose `name:` already matches the second half is accepted in one step, so
# a future shape change does not need a new rule.
#
# Prints one violation per line, format:
#   <required check name>: <file>:<caller job id> [-> <reusable file>]
# Empty when every check is in place.
shape_violations() { # $1=workflows dir
	python3 - "$1" <<'PY'
import glob
import os
import sys

import yaml

d = sys.argv[1]
files = sorted(set(
    glob.glob(os.path.join(d, "*.yml"))
    + glob.glob(os.path.join(d, "*.yaml"))
))

# An empty workflows directory has nothing to inspect. Returning the list of
# all required checks as "violations" is technically true (none of them are
# emitted by an empty tree) but it confuses the empty case with a populated
# tree where every caller is missing. The planted cases below prove the
# function does real work; this branch keeps the empty case indistinguishable
# from a populated tree with no violations, which is the same shape
# jobs-are-bounded.test.sh relies on for its watcher-vs-notifier distinction.
if not files:
    sys.exit(0)

reusable_specs = {}
for path in files:
    base = os.path.basename(path)
    if not base.startswith("reusable-"):
        continue
    try:
        with open(path) as fh:
            spec = yaml.safe_load(fh)
    except yaml.YAMLError:
        continue
    if isinstance(spec, dict):
        reusable_specs[base] = spec

# The exact names GitHub emits and the ruleset requires, as
# "<job id of the caller> / <name: of the called job>". The file is not part
# of the name. This list mirrors the branch ruleset and has to be updated with
# it: changing the ruleset without updating this list leaves a real required
# check unverified, and changing this list without the ruleset guards a
# phantom check GitHub will never report. It lives here, once, on purpose. A
# second copy in the shell above it would be the shape that put the manifest
# check in two files and the apt keyring bootstrap in four.
required = [
    "shell / test",
    "shell / shellcheck",
    "line-limit / line limit",
    "dco / Signed-off-by present on every commit",
    "workflow-lint / workflow-lint",
    "empty-diff / empty diff",
]

violations = []
for check in required:
    job_id, _, job_name = check.partition(" / ")
    found = False
    for path in files:
        base = os.path.basename(path)
        if base.startswith("reusable-"):
            continue  # a reusable does not emit a required check directly
        try:
            with open(path) as fh:
                spec = yaml.safe_load(fh)
        except yaml.YAMLError:
            continue
        if not isinstance(spec, dict):
            continue
        jobs = spec.get("jobs") or {}
        if not isinstance(jobs, dict):
            continue
        caller = jobs.get(job_id)
        if not isinstance(caller, dict):
            continue
        # Direct shape: the job carries the second half as its own name.
        # (No current required check uses this shape; the branch is here so
        # a future shape change does not need a new rule.)
        if caller.get("name") == job_name:
            found = True
            break
        # Caller shape: the caller uses a reusable, the reusable has a job
        # whose `name:` equals the second half.
        uses = caller.get("uses")
        if not isinstance(uses, str):
            continue
        target = os.path.basename(uses.lstrip("./"))
        rspec = reusable_specs.get(target)
        if not isinstance(rspec, dict):
            continue
        rjobs = rspec.get("jobs") or {}
        if not isinstance(rjobs, dict):
            continue
        for rname, rjob in rjobs.items():
            if not isinstance(rjob, dict):
                continue
            if rjob.get("name") == job_name:
                found = True
                break
        if found:
            break
    if not found:
        violations.append(
            f"{check}: no caller workflow pairs job id '{job_id}' "
            f"with a reusable job named '{job_name}'"
        )

for v in violations:
    print(v)
PY
}

# Verify drift.yml has the trigger set the header promises: schedule and
# workflow_dispatch only. Anything else is the design the file describes, but
# the actual file does not enforce it. The message names both reasons (the
# three-channel deadlock and the CDN staleness) so the next person who trips
# it does not have to read the header to find out why.
#
# YAML 1.1 parses bare `on` as the boolean True, so the triggers may be
# under either key. Accept both.
trigger_violations() { # $1=workflows dir
	python3 - "$1" <<'PY'
import os
import sys

import yaml

d = sys.argv[1]
path = os.path.join(d, "drift.yml")
if not os.path.exists(path):
    print("drift.yml: missing")
    sys.exit(0)
try:
    with open(path) as fh:
        spec = yaml.safe_load(fh)
except yaml.YAMLError as e:
    print(f"drift.yml: YAML parse error: {e}")
    sys.exit(0)
if not isinstance(spec, dict):
    print("drift.yml: not a mapping")
    sys.exit(0)
on = spec.get(True)
if not isinstance(on, dict):
    on = spec.get("on")
if not isinstance(on, dict):
    print("drift.yml: no on: triggers")
    sys.exit(0)
triggers = {k for k in on.keys() if isinstance(k, str)}
allowed = {"schedule", "workflow_dispatch"}
extras = sorted(triggers - allowed)
if extras:
    listed = ", ".join(extras)
    msg = (
        f"drift.yml: trigger(s) outside {{schedule, workflow_dispatch}}: "
        f"{listed}. Two reasons the file describes, neither visible from "
        f"the code: pull_request would deadlock three channels (the first "
        f"repository's pull request goes red on the others still carrying "
        f"the old copy); push: main reads its siblings from a CDN that "
        f"serves the previous file for several minutes after a merge. "
        f"Re-adding either brings that back."
    )
    print(msg)
PY
}

# --- the real tree ---------------------------------------------------------

check "every required check is emitted by its caller pairing in the real tree" \
	"" "$(shape_violations "$WORKFLOWS")"
check "drift.yml triggers only on schedule and workflow_dispatch in the real tree" \
	"" "$(trigger_violations "$WORKFLOWS")"

# --- planted violations ----------------------------------------------------

plant="$(mktemp -d)"
trap 'rm -rf "$plant"' EXIT
mkdir -p "$plant/.github/workflows"

# Snapshot the real tree so each plant starts from a true copy. The plants
# mutate from these; the originals stay untouched.
for f in "$WORKFLOWS"/*.yml; do
	cp "$f" "$plant/.github/workflows/$(basename "$f")"
done

# Confirm the plant actually changed the file before its result is read.
# `diff -q` returns 1 when files differ; that is the success case for a
# plant. The bare command would trip `set -e`, so the check is wrapped:
# "files differ" -> 1 (plant worked), "files match" -> 0 (plant did not).
plant_changed() { # $1=file  $2=bak
	if diff -q "$2" "$1" >/dev/null 2>&1; then
		echo 0
	else
		echo 1
	fi
}

# --- A.1: a renamed caller job id ------------------------------------------
#
# Rename `shell:` to `shellx:` in tests.yml. The required checks
# `shell / test` and `shell / shellcheck` would no longer be emitted under
# those names because no caller carries the id `shell` anywhere. The checker
# must report both, and the message must name the offending caller id.

cp "$plant/.github/workflows/tests.yml" "$plant/.github/workflows/tests.yml.bak"
python3 - "$plant/.github/workflows/tests.yml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = "  shell:\n    uses: ./.github/workflows/reusable-shell-ci.yml"
repl = "  shellx:\n    uses: ./.github/workflows/reusable-shell-ci.yml"
assert needle in src, "expected caller `shell` not found in tests.yml"
open(p, "w").write(src.replace(needle, repl))
PY
check "A.1: the plant renamed the caller id in tests.yml" \
	"1" "$(plant_changed "$plant/.github/workflows/tests.yml" "$plant/.github/workflows/tests.yml.bak")"
shape="$(shape_violations "$plant/.github/workflows")"
check "A.1: a renamed caller job id is reported for the first half" \
	"1" "$(printf '%s\n' "$shape" | grep -c '^shell / test:' || true)"
check "A.1: and for the second half too" \
	"1" "$(printf '%s\n' "$shape" | grep -c '^shell / shellcheck:' || true)"
check "A.1: and the message names the missing caller id" \
	"1" "$(printf '%s' "$shape" | grep -q "job id 'shell'" && echo 1 || echo 0)"
rm -f "$plant/.github/workflows/tests.yml.bak"

# Restore tests.yml for the next plant from the real tree.
cp "$WORKFLOWS/tests.yml" "$plant/.github/workflows/tests.yml"

# --- A.2: a renamed inner job name -----------------------------------------
#
# Rename `name: test` to `name: tests` in reusable-shell-ci.yml. The required
# check `shell / test` would no longer be emitted because no inner job in
# the reusable is named `test`. The checker must report exactly that one,
# and `shell / shellcheck` must still pass because its name half is
# untouched.

cp "$plant/.github/workflows/reusable-shell-ci.yml" "$plant/.github/workflows/reusable-shell-ci.yml.bak"
python3 - "$plant/.github/workflows/reusable-shell-ci.yml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = "  test:\n    name: test\n"
repl = "  test:\n    name: tests\n"
assert needle in src, "expected `name: test` not found in reusable-shell-ci.yml"
open(p, "w").write(src.replace(needle, repl))
PY
check "A.2: the plant renamed the inner job name in reusable-shell-ci.yml" \
	"1" "$(plant_changed "$plant/.github/workflows/reusable-shell-ci.yml" "$plant/.github/workflows/reusable-shell-ci.yml.bak")"
shape="$(shape_violations "$plant/.github/workflows")"
check "A.2: a renamed inner job name is reported for that half only" \
	"1" "$(printf '%s\n' "$shape" | grep -c '^shell / test:' || true)"
check "A.2: and the unaffected half still passes" \
	"0" "$(printf '%s\n' "$shape" | grep -c '^shell / shellcheck:' || true)"
check "A.2: and the message names the missing inner name" \
	"1" "$(printf '%s' "$shape" | grep -q "named 'test'" && echo 1 || echo 0)"

# Restore the reusable for the next plant.
cp "$plant/.github/workflows/reusable-shell-ci.yml.bak" "$plant/.github/workflows/reusable-shell-ci.yml"
rm -f "$plant/.github/workflows/reusable-shell-ci.yml.bak"

# --- B.1: drift.yml with a pull_request trigger ----------------------------
#
# Add `pull_request:` to drift.yml. The header says the file has to forbid
# this trigger; the checker must name it as the offender and state both
# reasons in the same message so the next person who trips it does not have
# to read the header to find out why.

cp "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak"
python3 - "$plant/.github/workflows/drift.yml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = "on:\n  schedule:\n    - cron: \"41 9 * * *\"\n  workflow_dispatch:\n"
repl = (
    "on:\n"
    "  schedule:\n"
    "    - cron: \"41 9 * * *\"\n"
    "  workflow_dispatch:\n"
    "  pull_request:\n"
)
assert needle in src, "expected on: block not found in drift.yml"
open(p, "w").write(src.replace(needle, repl))
PY
check "B.1: the plant added pull_request to drift.yml" \
	"1" "$(plant_changed "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak")"
msg="$(trigger_violations "$plant/.github/workflows")"
check "B.1: drift.yml with a pull_request trigger is reported" \
	"1" "$(printf '%s' "$msg" | grep -q 'pull_request' && echo 1 || echo 0)"
check "B.1: and the message names the deadlock" \
	"1" "$(printf '%s' "$msg" | grep -q 'deadlock' && echo 1 || echo 0)"
check "B.1: and the CDN staleness" \
	"1" "$(printf '%s' "$msg" | grep -q 'CDN' && echo 1 || echo 0)"

# Restore drift.yml for the next plant.
cp "$plant/.github/workflows/drift.yml.bak" "$plant/.github/workflows/drift.yml"
rm -f "$plant/.github/workflows/drift.yml.bak"

# --- B.2: drift.yml with a push: main trigger ------------------------------
#
# Add `push: branches: [main]` to drift.yml. The second defect the header
# names: the CDN serves the previous file for minutes after a merge, so
# every merge fired a red run describing a state that was already over.
# Same message; the design is the same.

cp "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak"
python3 - "$plant/.github/workflows/drift.yml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = "on:\n  schedule:\n    - cron: \"41 9 * * *\"\n  workflow_dispatch:\n"
repl = (
    "on:\n"
    "  schedule:\n"
    "    - cron: \"41 9 * * *\"\n"
    "  workflow_dispatch:\n"
    "  push:\n"
    "    branches: [main]\n"
)
assert needle in src, "expected on: block not found in drift.yml"
open(p, "w").write(src.replace(needle, repl))
PY
check "B.2: the plant added push: main to drift.yml" \
	"1" "$(plant_changed "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak")"
msg="$(trigger_violations "$plant/.github/workflows")"
check "B.2: drift.yml with a push: main trigger is reported" \
	"1" "$(printf '%s' "$msg" | grep -qE 'push(:|\b)' && echo 1 || echo 0)"
check "B.2: and again names both reasons in the same message" \
	"1" "$(printf '%s' "$msg" | grep -q 'deadlock' && printf '%s' "$msg" | grep -q 'CDN' && echo 1 || echo 0)"
rm -f "$plant/.github/workflows/drift.yml.bak"

# --- an empty workflows tree is reported as missing, not as a pass ---------
#
# Same shape as the real-tree check above, against a directory with no
# workflows at all. A scanner that misreads an empty directory as "no
# violations" would pass the real-tree case (the real tree IS empty of
# violations for both rules); distinguishing the two is the difference
# between a watcher and a notifier that always agrees.

empty="$(mktemp -d)"
check "an empty workflows directory reports no required-check violations" \
	"" "$(shape_violations "$empty")"
check "and reports drift.yml missing rather than passing by default" \
	"drift.yml: missing" "$(trigger_violations "$empty")"
rm -rf "$empty"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
