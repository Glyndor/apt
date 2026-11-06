#!/usr/bin/env bash
#
# The map in scripts/quality/suite-scope.txt is a claim: "a change outside these
# paths cannot change this suite's verdict". A claim nobody checks rots in three
# ways, and each one is a way to skip a suite that should have run:
#
#   * a suite the workflow runs has no entry (it then always runs, which is safe
#     but means the map no longer says what it was written to say) -- or an entry
#     names a suite the workflow no longer runs;
#   * an entry cites a path that does not exist, so a rename left a pattern that
#     matches nothing and the suite is silently skipped for the files that moved;
#   * an entry has no pattern at all.
#
# This reads the workflow's suite list and the map from the working tree and
# requires them to agree, with planted copies of each defect so the checker can
# be seen to fail.
#
# Requires: bash, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# problems <repo-root>: prints one line per problem, nothing when the map is sound.
problems() {
	python3 -I - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
wf = open(os.path.join(root, ".github/workflows/tests.yml")).read()
block = re.search(r"test-command: >-\n(.*?)(\n      #|\n\n|\Z)", wf, re.S).group(1)
suites = [l.strip()[2:] for l in block.splitlines() if l.strip().startswith("./tests/")]
scope, current = {}, None
for raw in open(os.path.join(root, "scripts/quality/suite-scope.txt")):
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line[:1].isspace():
        current = line.strip()
        if current in scope:
            print("listed twice: " + current)
        scope.setdefault(current, [])
    elif current is None:
        print("pattern before any suite: " + line.strip())
    else:
        scope[current].append(line.strip())
for s in suites:
    if s not in scope:
        print("no entry: " + s)
for s, patterns in scope.items():
    if s not in suites:
        print("not run by the workflow: " + s)
    if not patterns:
        print("no pattern: " + s)
    for p in patterns:
        base = p[:-3] if p.endswith("/**") else p
        if "*" in base:
            continue  # a glob inside a segment names no single path to test
        if not os.path.exists(os.path.join(root, base)):
            print("cites a path that does not exist: %s (%s)" % (p, s))
PY
}

# A tiny repository that has the workflow and the map, so a defect can be planted.
tree() {
	local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/.github/workflows" "$d/scripts/quality" "$d/scripts/a" "$d/tests/a"
	printf 'jobs:\n  s:\n    with:\n      test-command: >-\n        ./tests/ci/suites/check-suite-completeness.test.sh\n        ./tests/a/one.test.sh\n        ./tests/a/two.test.sh\n' > "$d/.github/workflows/tests.yml"
	printf 'x\n' > "$d/scripts/a/x.sh"
	printf 'tests/ci/suites/check-suite-completeness.test.sh\n\ttests/ci/**\n\ntests/a/one.test.sh\n\tscripts/a/**\n\ntests/a/two.test.sh\n\ttests/a/two.test.sh\n' > "$d/scripts/quality/suite-scope.txt"
	mkdir -p "$d/tests/ci"; : > "$d/tests/a/two.test.sh"
	echo "$d"
}

D="$(tree sound)"; check "control: a sound map reports nothing" "" "$(problems "$D")"

D="$(tree missing)"; printf '\ntests/a/three.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/suite-scope.txt"
check "an entry for a suite the workflow does not run is reported" "not run by the workflow: tests/a/three.test.sh" "$(problems "$D")"

D="$(tree noentry)"; sed -i 's|^        ./tests/a/two.test.sh|&\n        ./tests/a/four.test.sh|' "$D/.github/workflows/tests.yml"
check "a suite the workflow runs with no entry is reported" "no entry: tests/a/four.test.sh" "$(problems "$D")"

D="$(tree moved)"; rm -rf "$D/scripts/a"
check "a pattern whose directory was renamed away is reported" "cites a path that does not exist: scripts/a/** (tests/a/one.test.sh)" "$(problems "$D")"

D="$(tree file)"; rm "$D/tests/a/two.test.sh"
check "an exact file entry whose file is gone is reported" "cites a path that does not exist: tests/a/two.test.sh (tests/a/two.test.sh)" "$(problems "$D")"

D="$(tree empty)"; printf 'tests/a/one.test.sh\n' > "$D/scripts/quality/suite-scope.txt"
check "an entry with no pattern is reported" "no pattern: tests/a/one.test.sh" "$(problems "$D" | grep '^no pattern')"

D="$(tree twice)"; printf '\ntests/a/one.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/suite-scope.txt"
check "a suite listed twice is reported" "listed twice: tests/a/one.test.sh" "$(problems "$D")"

check "the real map agrees with the real workflow and the real tree" "" "$(problems "$HERE")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
