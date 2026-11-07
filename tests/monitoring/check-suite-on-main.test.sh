#!/usr/bin/env bash
# Behaviour tests for the contract of scripts/monitoring/check-suite-on-main.sh
# that does not depend on which event triggered it: the arguments it takes, the
# branch it resolves, the exit codes it returns, and the wiring in
# freshness.yml that makes the script run at all.
#
# The two event paths have their own files, because they answer different
# questions and a case that belongs to one of them reads as if it belonged to
# the other:
#
#   tests/monitoring/suite-on-main/check-suite-on-main-cron.test.sh  cron and pull_request
#   tests/monitoring/suite-on-main/check-suite-on-main-push.test.sh  push
#
# The fake `gh` all three use comes from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: bash, jq, GNU coreutils.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$HERE/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

pass=0
fail=0

check() { # <description> <expected> <actual>
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

says() { # $1=output  $2=pattern
	printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0
}

# ===========================================================================
# PATH-INDEPENDENT CONTRACT
#
# Behaviors that apply regardless of GITHUB_EVENT_NAME.
# ===========================================================================

# --- the branch is an argument, not a constant ------------------------------
#
# The job passes main, and the script must not have main baked in: a copy of
# this check pointed at a release branch has to read that branch.
row completed success > "$WORK/success.resp"
rm -f "$WORK/gh.log"; : > "$WORK/gh.log"
STUB_LOG="$WORK/gh.log" STUB_RESPONSE="$WORK/success.resp" \
	PATH="$WORK/bin:$PATH" GH_TOKEN=dummy \
	"$GATE" "$REPO" "$WF" release >/dev/null 2>&1
check "a branch other than main reaches the URL" "1" "$(logged 'branch=release')"

# --- the branch defaults to main --------------------------------------------
rm -f "$WORK/gh.log"; : > "$WORK/gh.log"
STUB_LOG="$WORK/gh.log" STUB_RESPONSE="$WORK/success.resp" \
	PATH="$WORK/bin:$PATH" GH_TOKEN=dummy \
	"$GATE" "$REPO" "$WF" >/dev/null 2>&1
check "an omitted branch defaults to main" "1" "$(logged 'branch=main')"

# --- a failing gh must fail the check --------------------------------------
#
# `set -euo pipefail` is meant to carry a non-zero `gh` through. An API error
# read as "no rows" would be reported as a branch with no history, which sends
# the reader after a workflow that was never missing.

row completed success > "$WORK/apifail.resp"
out="$(STUB_EXIT_CODE=1 run_gate "$WORK/apifail.resp")"; rc=$?
check "a failing gh api call fails the check" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and is not reported as an empty history" "0" \
	"$(says "$out" 'no completed run')"

# --- missing arguments are refused -----------------------------------------
#
# Exit 2 rather than 1, so a wiring mistake in the workflow reads differently
# from a red branch. Both are red; only one of them means main is broken.

out="$(PATH="$WORK/bin:$PATH" "$GATE" 2>&1)"; rc=$?
check "no arguments is a usage error, not a verdict" "2" "$rc"
check "and it prints the usage line" "1" "$(says "$out" 'usage:')"
out="$(PATH="$WORK/bin:$PATH" "$GATE" "$REPO" 2>&1)"; rc=$?
check "a repository without a workflow file is a usage error too" "2" "$rc"

# --- the workflow wires it up ----------------------------------------------
#
# The script is only a report if something calls it. Every assertion above
# passes on a script no workflow invokes, and that is the shape this repository
# has shipped before: a suite sitting in tests/ that CI never ran.

FRESHNESS="$HERE/.github/workflows/freshness.yml"
uncommented() { grep -v '^[[:space:]]*#' "$1"; }
check "freshness.yml invokes the script" "1" \
	"$(says "$(uncommented "$FRESHNESS")" 'scripts/monitoring/check-suite-on-main.sh')"
check "and passes it the suite workflow to read" "1" \
	"$(says "$(uncommented "$FRESHNESS")" "$WF main")"
check "and the job declares a bound" "1" \
	"$(says "$(sed -n '/^  suite-on-main:/,$p' "$FRESHNESS")" 'timeout-minutes:')"
check "and grants actions: read to reach the run history" "1" \
	"$(says "$(sed -n '/^  suite-on-main:/,$p' "$FRESHNESS")" 'actions: read')"
check "and reads the API with the job's own token" "1" \
	"$(says "$(sed -n '/^  suite-on-main:/,$p' "$FRESHNESS")" 'GH_TOKEN: ')"

# The push trigger is half of what makes this report on the next landing rather
# than only on the next tick. Dropping it leaves the schedule, which reads as
# working, so it is asserted here rather than left to be noticed.
check "freshness.yml reports on a push to main" "1" \
	"$(says "$(uncommented "$FRESHNESS")" 'branches: \[main\]')"
check "and on its schedule" "1" \
	"$(says "$(uncommented "$FRESHNESS")" 'cron:')"

# The reason this must not become a required check has to travel with the job.
# It is not enforceable from here (a ruleset lives outside the repository), so
# what is enforceable is that the next person reads the reason before making it
# one.
check "and the job carries the note that it must not be required" "1" \
	"$(says "$(sed -n '/^  # Reports the verdict of the suite on main/,/^  suite-on-main:/p' "$FRESHNESS")" \
		'MUST NOT BECOME A REQUIRED STATUS CHECK')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
