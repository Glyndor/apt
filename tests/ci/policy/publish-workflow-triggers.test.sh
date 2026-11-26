#!/usr/bin/env bash
#
# publish.yml and health-check.yml run with credentials and check out the
# revision they are triggered for. Their documented contract is schedule plus
# manual dispatch; event-driven runs could execute untrusted PR code with those
# credentials. Parse YAML so a trigger cannot hide in another valid `on:` shape
# or under PyYAML's YAML 1.1 boolean interpretation.
#
# Each forbidden event is planted separately in copied workflows. The diff
# check proves the sabotage took effect before its refusal is counted.
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOWS="$HERE/.github/workflows"
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

# BaseLoader preserves `on` as a string and handles YAML map, list, and scalar.
violations() { # $1 = workflow directory
	python3 -I - "$1" <<'PY'
import os, sys, yaml

directory = sys.argv[1]
contracts = {
    "publish.yml": {"schedule", "workflow_dispatch"},
    "health-check.yml": {"schedule", "workflow_dispatch"},
}
for filename, allowed in contracts.items():
    path = os.path.join(directory, filename)
    try:
        with open(path, encoding="utf-8") as stream:
            doc = yaml.load(stream, Loader=yaml.BaseLoader)
    except (OSError, yaml.YAMLError) as error:
        print(f"{filename}: cannot parse workflow: {error}")
        continue
    if not isinstance(doc, dict) or "on" not in doc:
        print(f"{filename}: missing on: trigger declaration")
        continue
    events = doc["on"]
    if isinstance(events, dict):
        actual = set(events)
    elif isinstance(events, list):
        actual = set(events)
    elif isinstance(events, str):
        actual = {events}
    else:
        print(f"{filename}: on: must be a map, list, or scalar")
        continue
    extra, missing = sorted(actual - allowed), sorted(allowed - actual)
    if extra or missing:
        print(f"{filename}: extra={','.join(extra) or '-'}; missing={','.join(missing) or '-'}")
PY
}

check "the live publisher workflows have exactly their documented triggers" \
	"" "$(violations "$WORKFLOWS")"

# Exercise these shapes through violations(), the parser used on real files.
for shape in map list scalar; do
	dir="$WORK/shape-$shape"; mkdir -p "$dir"
	python3 -I - "$dir" "$shape" <<'PY'
import os, sys, yaml
directory, shape = sys.argv[1:]
events = {'schedule': None, 'workflow_dispatch': None}
if shape == 'list': events = list(events)
if shape == 'scalar': events = 'schedule'
for filename in ('publish.yml', 'health-check.yml'):
    path = os.path.join(directory, filename)
    with open(path, 'w', encoding='utf-8') as stream:
        yaml.dump({'on': events}, stream, sort_keys=False)
PY
	result="$(violations "$dir")"
	if [ "$shape" = scalar ]; then
		expected="$(printf 'publish.yml: extra=-; missing=workflow_dispatch\nhealth-check.yml: extra=-; missing=workflow_dispatch')"
	else
		expected=""
	fi
	check "the YAML $shape event form is checked by the live parser" "$expected" "$result"
done

# Add one forbidden trigger to copies of both protected workflows. Check each
# diff before requiring its named refusal, so an inert plant cannot look green.
plant_and_check() { # $1=event
	local event="$1" dir="$WORK/plant-$1"
	rm -rf "$dir"; mkdir -p "$dir"
	cp "$WORKFLOWS/publish.yml" "$dir/publish.yml"
	cp "$WORKFLOWS/health-check.yml" "$dir/health-check.yml"
	for file in publish.yml health-check.yml; do
		cp "$dir/$file" "$dir/$file.before"
		python3 -I - "$dir/$file" "$event" <<'PY'
import sys, yaml
path, event = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    doc = yaml.load(stream, Loader=yaml.BaseLoader)
doc['on'][event] = None
with open(path, 'w', encoding='utf-8') as stream:
    yaml.dump(doc, stream, sort_keys=False)
PY
		if diff -q "$dir/$file.before" "$dir/$file" >/dev/null; then
			echo "SABOTAGE INERT: $file did not change when planting $event"
			return 1
		fi
		echo "SABOTAGE APPLIED: $file now contains $event"
	done
	local result expected
	result="$(violations "$dir")"
	expected="$(printf 'publish.yml: extra=%s; missing=-\nhealth-check.yml: extra=%s; missing=-' "$event" "$event")"
	check "planted $event is rejected in both copied workflows" "$expected" "$result"
}

for event in pull_request pull_request_target workflow_run push; do
	plant_and_check "$event"
done

echo
# --- the job that holds the keys runs on main only --------------------------------------------------------
# A manual run starts from any branch. The job declares the environment whose branch policy admits main, and its
# first step, before anything is checked out, refuses any other ref.
guard_problems() { # $1 = workflow file
	python3 -I - "$1" <<'PY'
import sys, yaml
doc = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=yaml.BaseLoader)
job = doc["jobs"]["publish"]
if job.get("environment") != "publish":
    print("the publish job does not declare the environment publish")
first = job["steps"][0]
if "uses" in first or first.get("env", {}).get("REF") != "${{ github.ref }}" or "refs/heads/main" not in first.get("run", ""):
    print("the first step of the publish job is not the refusal of any ref but main")
PY
}
check "publish.yml runs its keys on main only" "" "$(guard_problems "$WORKFLOWS/publish.yml")"
run="$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["publish"]["steps"][0]["run"])' "$WORKFLOWS/publish.yml")"
for ref in refs/heads/main refs/heads/mainx refs/heads/fix refs/tags/v1 refs/pull/3/merge ""; do
	rc=0; REF="$ref" bash -c "$run" > "$WORK/guard.out" 2>&1 || rc=$?
	if [ "$ref" = refs/heads/main ]; then
		check "the first step lets main through" "0" "$rc"
	else
		check "the first step refuses '$ref' and says nothing is published" "1 1" "$rc $(grep -c 'nothing is published' "$WORK/guard.out")"
	fi
done
for sabotage in environment first-step; do
	python3 -I - "$WORKFLOWS/publish.yml" "$WORK/$sabotage.yml" "$sabotage" <<'PY'
import sys, yaml
doc = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=yaml.BaseLoader)
job = doc["jobs"]["publish"]
if sys.argv[3] == "environment":
    del job["environment"]
else:
    job["steps"].pop(0)
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
	check "a publish job without its $sabotage is reported" "1" "$([ -n "$(guard_problems "$WORK/$sabotage.yml")" ] && echo 1 || echo 0)"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
