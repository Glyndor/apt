#!/usr/bin/env bash
#
# roster-releases.yml is the advisory check that tells a pull request when a product of the
# roster has no usable release. Nothing else exercises the workflow itself, so deleting it or
# its step would leave every suite green. This requires it to exist, to run only on pull
# requests, to be filtered to the files that change the answer, to call the script, to hold
# no job a required check could depend on, and to be bounded.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

verdict="$(python3 - "$HERE/.github/workflows/roster-releases.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
on = doc.get(True, doc.get("on", {}))
problems = []
if set(on) != {"pull_request"}:
    problems.append("triggers are not exactly pull_request")
paths = set((on.get("pull_request") or {}).get("paths") or [])
need = {".github/workflows/publish.yml", ".github/workflows/roster-releases.yml", "scripts/verify/roster-has-releases.sh"}
if paths != need:
    problems.append(f"paths differ: missing {sorted(need - paths)} extra {sorted(paths - need)}")
jobs = doc.get("jobs") or {}
if len(jobs) != 1:
    problems.append("expected exactly one job")
for job in jobs.values():
    if not job.get("timeout-minutes"):
        problems.append("the job has no timeout")
    runs = [s.get("run", "") for s in job.get("steps", [])]
    if not any("scripts/verify/roster-has-releases.sh" in r for r in runs):
        problems.append("no step runs the script")
    if any(s.get("continue-on-error") for s in job.get("steps", [])) or job.get("continue-on-error"):
        problems.append("a step or the job tolerates failure")
print("ok" if not problems else "; ".join(problems))
PY
)"
check "the roster-releases workflow is pull-request only, path-filtered, bounded and runs the script" "ok" "$verdict"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
