#!/usr/bin/env bash
# Every `actions/checkout` of every workflow passes `persist-credentials: false`.
#
# The default writes the job token into `.git/config` for the rest of the job,
# beside whatever else that job holds: in a publish job, the signing key. The
# organisation's rule is that every checkout passes `false` unless the job
# pushes with git, and no job of this repository does. Until this file, the
# setting was measured once, by reading the workflows, and nothing failed when
# a checkout came back without it, or with `true`, or when a new workflow
# arrived with the default.
#
# The rule has no exception listed here, and that is deliberate: a job that
# pushes with git is the one case the rule allows, and adding one is a change
# to this file that says which job and why, not a line a pull request can slip
# into a workflow. Both `.yml` and `.yaml` are read, and the reusable workflows
# too, because a reusable runs with its caller's token.
#
# A workflow that cannot be parsed, or a tree with no workflow or no checkout,
# is a failure and not a pass: a checker that inspects nothing prints the same
# line as one that inspected everything.
#
# Every refusal is asserted by what it names (the file, the job and the step),
# and each is paired with the same workflow made right, so a fixture refused
# for another reason cannot satisfy it.
#
# Requires: python3 with PyYAML.
# The fixtures carry a literal `${{ ... }}`; the single quotes are the point.
# shellcheck disable=SC2016
set -u

# The repository root, found by walking up from this file, so the same text
# serves wherever the suites are grouped.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -d "$HERE/.github/workflows" ]; do
	[ "$HERE" != / ] || { echo "FAIL  no .github/workflows above ${BASH_SOURCE[0]}"; exit 1; }
	HERE="$(dirname "$HERE")"
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# One line per finding, `<file>: <job>: <what>`, then a last line `checked <n>
# checkout(s) in <m> workflow(s)`. The last line is how a case tells a tree
# that was inspected from one that was not.
checkouts() { # $1=workflows dir
	python3 -I - "$1" <<'PY'
import glob
import os
import sys

import yaml

directory = sys.argv[1]
files = sorted(set(
    glob.glob(os.path.join(directory, "*.yml"))
    + glob.glob(os.path.join(directory, "*.yaml"))
))
checked = 0
for path in files:
    name = os.path.basename(path)
    try:
        with open(path) as handle:
            spec = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError):
        print(f"{name}: -: cannot be read as a workflow, so its checkouts are unknown")
        continue
    if not isinstance(spec, dict):
        print(f"{name}: -: is not a workflow, so its checkouts are unknown")
        continue
    jobs = spec.get("jobs")
    if not isinstance(jobs, dict):
        continue
    for job_id, job in jobs.items():
        steps = job.get("steps") if isinstance(job, dict) else None
        for index, step in enumerate(steps or [], start=1):
            uses = step.get("uses") if isinstance(step, dict) else None
            if not isinstance(uses, str) or uses.split("@", 1)[0].lower() != "actions/checkout":
                continue
            checked += 1
            options = step.get("with")
            value = options.get("persist-credentials") if isinstance(options, dict) else None
            # `false` is the YAML boolean or the string a quoted `false` gives.
            if value is False or (isinstance(value, str) and value == "false"):
                continue
            shown = "not set" if value is None else repr(value)
            print(f"{name}: {job_id}: step {index} checks out with persist-credentials {shown}")
print(f"checked {checked} checkout(s) in {len(files)} workflow(s)")
PY
}
findings() { checkouts "$1" | grep -v '^checked '; }
count() { checkouts "$1" | sed -n 's/^checked \([0-9]*\) checkout.*/\1/p'; }

# --- the real tree ----------------------------------------------------------------
real_findings="$(findings "$HERE/.github/workflows")"
check "every checkout of every workflow here passes persist-credentials: false" "" "$real_findings"
check "and the check looked at some" "1" "$([ "$(count "$HERE/.github/workflows")" -ge 1 ] && echo 1 || echo 0)"

# --- planted workflows ------------------------------------------------------------
# A workflow with one checkout whose `with:` block is given, in a directory of
# its own, so each case reads only what it planted.
tree() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; printf '%s' "$WORK/t"; }
workflow() { # $1=dir $2=file name $3=lines of the checkout step, after `- uses:`
	{
		printf 'name: Plant\non: push\npermissions:\n  contents: read\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n'
		printf '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n'
		[ -z "$3" ] || printf '%s\n' "$3"
		printf '      - run: echo built\n'
	} > "$1/$2"
}
RIGHT='        with:
          persist-credentials: false'

d="$(tree)"; workflow "$d" good.yml "$RIGHT"
check "a checkout that passes persist-credentials: false is accepted" "" "$(findings "$d")"
check "and is counted" "1" "$(count "$d")"

d="$(tree)"; workflow "$d" bare.yml ""
check "a checkout with no with: block is refused" "bare.yml: build: step 1 checks out with persist-credentials not set" "$(findings "$d")"

d="$(tree)"; workflow "$d" other.yml '        with:
          fetch-depth: 0'
check "a checkout whose with: block does not set it is refused" "other.yml: build: step 1 checks out with persist-credentials not set" "$(findings "$d")"

d="$(tree)"; workflow "$d" on.yml '        with:
          persist-credentials: true'
check "a checkout that passes persist-credentials: true is refused" "on.yml: build: step 1 checks out with persist-credentials True" "$(findings "$d")"

d="$(tree)"; workflow "$d" expr.yml '        with:
          persist-credentials: ${{ inputs.keep }}'
check "a checkout that takes it from an expression is refused" "expr.yml: build: step 1 checks out with persist-credentials '\${{ inputs.keep }}'" "$(findings "$d")"

d="$(tree)"; workflow "$d" quoted.yml '        with:
          persist-credentials: "false"'
check "a quoted false is the same value and is accepted" "" "$(findings "$d")"

d="$(tree)"; workflow "$d" quoted-true.yml '        with:
          persist-credentials: "true"'
check "and a quoted true is refused" "quoted-true.yml: build: step 1 checks out with persist-credentials 'true'" "$(findings "$d")"

# --- which workflows are read -----------------------------------------------------
d="$(tree)"; workflow "$d" dot-yaml.yaml ""
check "a workflow with the .yaml extension is read" "dot-yaml.yaml: build: step 1 checks out with persist-credentials not set" "$(findings "$d")"
workflow "$d" dot-yaml.yaml "$RIGHT"
check "and accepted once it passes false" "" "$(findings "$d")"

d="$(tree)"; workflow "$d" reusable-thing.yml ""
check "a reusable workflow is read" "reusable-thing.yml: build: step 1 checks out with persist-credentials not set" "$(findings "$d")"

d="$(tree)"
{
	printf 'name: Two\non: push\npermissions:\n  contents: read\njobs:\n'
	printf '  first:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n'
	printf '  second:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo first\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n'
} > "$d/two.yml"
check "a second job with a bad checkout is refused, and the good first one is not" "two.yml: second: step 2 checks out with persist-credentials not set" "$(findings "$d")"
check "and both checkouts are counted" "2" "$(count "$d")"

d="$(tree)"
printf 'name: Other\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/cache@0123456789abcdef0123456789abcdef01234567 # v4\n        with:\n          path: x\n          key: y\n' > "$d/cache.yml"
check "an action that is not checkout needs no setting" "" "$(findings "$d")"
check "and is not counted as a checkout" "0" "$(count "$d")"

# --- what the check refuses to guess ----------------------------------------------
d="$(tree)"; printf 'name: [\n' > "$d/broken.yml"
check "a workflow that does not parse is refused, not skipped" "broken.yml: -: cannot be read as a workflow, so its checkouts are unknown" "$(findings "$d")"

d="$(tree)"; printf -- '- not\n- a workflow\n' > "$d/list.yml"
check "a file that is not a workflow is refused, not skipped" "list.yml: -: is not a workflow, so its checkouts are unknown" "$(findings "$d")"

d="$(tree)"
check "a directory with no workflow counts zero checkouts, which the real-tree case above refuses" "0" "$(count "$d")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
