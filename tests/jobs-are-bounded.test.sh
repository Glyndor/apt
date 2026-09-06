#!/usr/bin/env bash
# Every job under .github/workflows/ that is not a caller declares a
# timeout-minutes.
#
# A caller job is one whose declaration includes `uses:` -- it delegates to a
# reusable workflow and, per GitHub's "Supported keywords for jobs that call
# a reusable workflow" list, `timeout-minutes` is not among the keys it can
# carry. That is why the exemption is written structurally (the job has no
# `uses:` key) rather than as a list of job names: the structural rule keeps
# a new caller free of the bound and keeps an existing caller from acquiring
# one.
#
# A gate that inspected nothing prints the same success line as one that did,
# so the cases below plant a violation and require red. The planted case
# seeds a workflow with a job that has no bound and the test names the file
# and job that lost it; the second planted case has a caller plus a job that
# is not a caller, and the test names only the second.
#
# Requires: python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$HERE/.github/workflows"

pass=0
fail=0

check() { # $1=description $2=expected $3=actual
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

# Walk every workflow in the given directory, every job. A caller (any job
# whose declaration includes `uses:`) is exempt; every other job must declare
# `timeout-minutes`. Prints one "<file>:<job>" per violation; nothing when
# the tree is clean.
missing_bounds() { # $1=workflows dir
	python3 - "$1" <<'PY'
import sys
import glob
import os

import yaml

d = sys.argv[1]
missing = []
files = sorted(set(
    glob.glob(os.path.join(d, "*.yml"))
    + glob.glob(os.path.join(d, "*.yaml"))
))
for path in files:
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
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        # A caller carries `uses:` and nothing the runner executes inline;
        # GitHub's caller-keyword list excludes `timeout-minutes`, so a
        # caller cannot declare one and the test must exempt it.
        if "uses" in job:
            continue
        if "timeout-minutes" not in job:
            missing.append(f"{os.path.basename(path)}:{job_id}")
for entry in missing:
    print(entry)
PY
}

says() { # $1=output  $2=pattern
	printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0
}

# --- the real tree passes --------------------------------------------------

list="$(missing_bounds "$WORKFLOWS")"
check "every non-caller job in the real tree declares timeout-minutes" "" "$list"

# --- a planted uncapped job is caught and named ----------------------------
#
# The same script (and the same rule) is run against a temporary tree that
# carries one job without a bound. The test must name the file and the job.
# A scanner that returns nothing on this tree is the failure the planted case
# exists to close: it reads as "no violations found" on a tree that has one.

plant="$(mktemp -d)"
trap 'rm -rf "$plant"' EXIT
mkdir -p "$plant/.github/workflows"

cat >"$plant/.github/workflows/planted.yml" <<'YML'
name: planted
on: [push]
jobs:
  uncapped:
    runs-on: ubuntu-latest
    steps:
      - run: echo uncapped
YML

list="$(missing_bounds "$plant/.github/workflows")"
check "a planted job without timeout-minutes is named" "planted.yml:uncapped" "$list"

# --- a caller (with or without other keys) is exempt -----------------------

cat >"$plant/.github/workflows/mixed.yml" <<'YML'
name: mixed
on: [push]
jobs:
  pure-caller:
    uses: ./.github/workflows/whatever.yml
  caller-with-permissions:
    permissions:
      contents: read
    uses: ./.github/workflows/whatever.yml
  caller-with-with:
    uses: ./.github/workflows/whatever.yml
    with:
      foo: bar
YML

list="$(missing_bounds "$plant/.github/workflows")"
check "a pure caller is exempt" "0" "$(says "$list" 'mixed.yml:pure-caller')"
check "a caller with permissions is also exempt" "0" \
	"$(says "$list" 'mixed.yml:caller-with-permissions')"
check "a caller with a with: block is also exempt" "0" \
	"$(says "$list" 'mixed.yml:caller-with-with')"
check "and the test names no caller" "" \
	"$(printf '%s\n' "$list" | grep -E ':(pure-caller|caller-with-permissions|caller-with-with)$' || true)"

# --- an empty workflows tree is reported as nothing, not as a pass ---------
#
# Same shape as the real-tree check above, against a directory with no
# workflows at all. A scanner that misreads an empty directory as "no
# violations" passes the real-tree case (the real tree IS empty of
# violations); distinguishing the two is the difference between a watcher
# and a notifier that always agrees.

empty="$(mktemp -d)"
list="$(missing_bounds "$empty")"
rm -rf "$empty"
check "an empty workflows directory reports nothing to inspect" "" "$list"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
