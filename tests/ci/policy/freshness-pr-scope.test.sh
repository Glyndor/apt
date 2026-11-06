#!/usr/bin/env bash
#
# freshness.yml answers questions about main and about crons, never about the
# change in a pull request, so it must not run on every pull request. It may
# run on one that changes what it is made of: the workflow itself and the two
# reusables it calls. A filter that left its own file out would stop testing the
# workflow it guards, and a filter on a required check would never report it, so
# this also requires that no job of the file is one the repository requires.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# Prints "ok", or what is wrong with the pull_request trigger of a workflow.
scope() { # $1 = workflow file
	python3 - "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
on = doc.get(True, doc.get("on", {}))
present = "pull_request" in on
pr = on.get("pull_request")
need = {".github/workflows/freshness.yml",
        ".github/workflows/reusable-dependabot-freshness.yml",
        ".github/workflows/reusable-schedule-freshness.yml"}
if not present:
    print("ok")  # no pull_request trigger at all is also fine
elif not isinstance(pr, dict) or "paths" not in pr:
    print("the pull_request trigger has no paths filter")
else:
    missing = sorted(need - set(pr["paths"]))
    extra = sorted(set(pr["paths"]) - need)
    print("ok" if not missing and not extra else
          "paths missing: %s; paths not allowed: %s" % (missing, extra))
PY
}

mkdir -p "$WORK/c"
plant() { # $1 = file, rest = the pull_request block lines
	local f="$1"; shift
	{ printf 'on:\n'; printf '  %s\n' "$@"; printf 'jobs: {}\n'; } > "$f"
}
FULL=('pull_request:' '  paths:' '    - .github/workflows/freshness.yml' '    - .github/workflows/reusable-dependabot-freshness.yml' '    - .github/workflows/reusable-schedule-freshness.yml')

plant "$WORK/c/good.yml" "${FULL[@]}"
check "the three files and nothing else pass" "ok" "$(scope "$WORK/c/good.yml")"
plant "$WORK/c/unfiltered.yml" 'pull_request:'
check "an unfiltered pull_request trigger is reported" "the pull_request trigger has no paths filter" "$(scope "$WORK/c/unfiltered.yml")"
plant "$WORK/c/noself.yml" 'pull_request:' '  paths:' '    - .github/workflows/reusable-dependabot-freshness.yml' '    - .github/workflows/reusable-schedule-freshness.yml'
check "a filter that leaves out the workflow itself is reported" \
	"paths missing: ['.github/workflows/freshness.yml']; paths not allowed: []" "$(scope "$WORK/c/noself.yml")"
plant "$WORK/c/wide.yml" "${FULL[@]}" '    - README.md'
check "a filter wider than the three files is reported" \
	"paths missing: []; paths not allowed: ['README.md']" "$(scope "$WORK/c/wide.yml")"

check "the live freshness workflow passes" "ok" "$(scope "$HERE/.github/workflows/freshness.yml")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
