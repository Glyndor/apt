#!/usr/bin/env bash
#
# Every file in tests/ must actually be invoked by a workflow, and every test a
# workflow invokes must exist.
#
# scripts/check-test-coverage.sh watches that each script has a test. Nothing
# watched that the test RUNS. That gap was live when this was written:
# tests/locale-pinned.test.sh had been added, passed locally, and no workflow
# called it -- a guard against unpinned collation that CI never executed.
#
# An unregistered test is worse than a missing one. A missing test is caught by
# the coverage gate. An unregistered test sits in tests/, passes when anyone
# runs it by hand, and reads as coverage from every angle except the only one
# that matters.
#
# This file is in tests/, so it is in its own input set: it must appear in a
# workflow like everything else here, and the case at the end requires it.
#
# It scans every workflow rather than one file, so splitting CI across several
# workflows does not silently drop a suite.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Every mention of a test script across all workflows, comments excluded. A
# suite named only in a comment is not run, and this check exists precisely to
# stop prose from counting as wiring.
invoked() {
	# Drop whole-line comments before matching. A line that merely MENTIONS a
	# suite -- "# see ./tests/x.test.sh for why" -- is prose, and counting it
	# would let a comment stand in for wiring. The probe at the end caught this
	# on the first run: the doc comment above claimed comments were excluded
	# while the code did not exclude them.
	#
	# Only lines whose first non-space character is `#` are dropped, so a real
	# invocation with a trailing comment still counts.
	grep -rh -v '^[[:space:]]*#' .github/workflows/ 2>/dev/null \
		| grep -oE '\./tests/[A-Za-z0-9_.-]+\.test\.sh' \
		| sed 's|^\./||' | LC_ALL=C sort -u
}
present() {
	find tests -maxdepth 1 -name '*.test.sh' -printf '%p\n' 2>/dev/null | LC_ALL=C sort -u
}

# --- every test present is invoked ------------------------------------------
missing="$(LC_ALL=C comm -23 <(present) <(invoked | LC_ALL=C sort -u) | tr '\n' ' ')"
check "every test in tests/ is invoked by a workflow" "" "${missing% }"

# --- every test invoked exists ----------------------------------------------
#
# The other direction is a different failure: a workflow naming a file that is
# not there fails the run with "No such file", which is loud. It is here because
# a rename that updates one side and not the other should be named by this test
# rather than diagnosed from a runner log.
absent="$(LC_ALL=C comm -13 <(present) <(invoked | LC_ALL=C sort -u) | tr '\n' ' ')"
check "every test a workflow invokes exists" "" "${absent% }"

# --- this file is itself invoked --------------------------------------------
#
# The watcher is inside its own input set. Removing it from the workflow makes
# the first case red, and this one names it directly so the reason is not
# buried in a list.
check "this watcher is itself invoked by a workflow" "1" \
	"$(invoked | grep -cx 'tests/ci-runs-every-test.test.sh')"

# --- the check can see a violation ------------------------------------------
#
# Without this it is a comparison that always agrees. The fixture holds one
# registered test and one that is not, and the pattern must report exactly the
# unregistered one.
probe="$(mktemp -d)"
mkdir -p "$probe/tests" "$probe/.github/workflows"
: > "$probe/tests/wired.test.sh"
: > "$probe/tests/orphan.test.sh"
printf 'jobs:\n  t:\n    steps:\n      - run: ./tests/wired.test.sh\n' \
	> "$probe/.github/workflows/ci.yml"
# A comment naming the orphan must NOT count as wiring.
printf '# see ./tests/orphan.test.sh for the rationale\n' \
	>> "$probe/.github/workflows/ci.yml"
seen="$( cd "$probe" || exit 1
	inv="$(grep -rh -v '^[[:space:]]*#' .github/workflows/ \
		| grep -oE '\./tests/[A-Za-z0-9_.-]+\.test\.sh' \
		| sed 's|^\./||' | LC_ALL=C sort -u)"
	pre="$(find tests -maxdepth 1 -name '*.test.sh' -printf '%p\n' | LC_ALL=C sort -u)"
	LC_ALL=C comm -23 <(printf '%s\n' "$pre") <(printf '%s\n' "$inv") | tr '\n' ' ' )"
rm -rf "$probe"
check "and it reports an unregistered test when there is one" \
	"tests/orphan.test.sh" "${seen% }"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
