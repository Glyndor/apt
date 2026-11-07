#!/usr/bin/env bash
# Behaviour tests for the cron and pull_request path of
# scripts/monitoring/check-suite-on-main.sh.
#
# The script's failure mode is not a crash, it is agreement. A reporter that
# reads the wrong field, asks for the wrong runs, or walks past an empty history
# prints the same green line as one that did the work, and green is exactly what
# nobody questions. So the cases below plant each answer and require the script
# to tell them apart: a completed failing run must be reported, a completed
# successful one must be silent, and an empty history must say it found nothing
# rather than pass.
#
# On schedule and pull_request the script reads a 30-item page of completed runs
# and takes the greatest created_at, skipping cancelled runs and counting how
# many it skipped. The push path is a different set of cases and lives in
# tests/monitoring/suite-on-main/check-suite-on-main-push.test.sh; the path-independent
# contract (arguments, branch, exit codes) lives in
# tests/monitoring/check-suite-on-main.test.sh. The fake `gh` both of them use
# comes from tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: bash, jq, GNU coreutils.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
# SCHEDULE AND PULL_REQUEST PATH
#
# The newest completed run on main, from a 30-item page sorted by created_at
# here. Cancelled runs are passed over and counted; an all-cancelled page
# fails with a no-verdict message; an empty page fails with the unknown-state
# message.
# ===========================================================================

# --- a completed failing run is reported ------------------------------------
#
# The case the script exists for. Twenty minutes of red main went unreported
# because nothing read this answer, so it is not enough that the script exits
# non-zero: the message has to name the conclusion, the run and the commit, or
# the reader is told there is a problem and not where.

row completed failure > "$WORK/failure.resp"
out="$(run_gate "$WORK/failure.resp")"; rc=$?
check "a completed failing run fails the check" "1" "$rc"
check "and the message names the conclusion it read" "1" \
	"$(says "$out" "concluded 'failure'")"
check "and names the workflow and the branch" "1" \
	"$(says "$out" "$WF concluded 'failure' on $BRANCH")"
check "and names the run number so the run can be opened" "1" \
	"$(says "$out" 'run #314')"
check "and names the commit that is red" "1" "$(says "$out" '4f1c0d9')"
check "and links the run" "1" \
	"$(says "$out" 'actions/runs/9001')"
check "and is not the empty-history message" "0" \
	"$(says "$out" 'no completed run')"

# --- a completed successful run is silent -----------------------------------
#
# Without this case the script could report every run as red and every case
# above would still be green. This is what makes the one above mean something.

row completed success > "$WORK/success.resp"
out="$(run_gate "$WORK/success.resp")"; rc=$?
check "a completed successful run passes" "0" "$rc"
check "and reports which run it read" "1" "$(says "$out" 'run #314')"
check "and says nothing about a failure" "0" "$(says "$out" '::error')"

# --- an empty history says it found nothing ---------------------------------
#
# The third answer, and the one a careless reporter turns into a pass: no rows
# came back, so nothing was inspected, and a checker that inspected nothing
# prints the same success line as one that inspected everything.

: > "$WORK/empty.resp"
out="$(run_gate "$WORK/empty.resp")"; rc=$?
check "an empty run history fails rather than passing silently" "1" "$rc"
check "and says it found no completed run" "1" \
	"$(says "$out" "no completed run of $WF on $BRANCH is on record")"
check "and says the state of the branch is unknown" "1" \
	"$(says "$out" 'unknown')"
check "and is not the red-branch message" "0" "$(says "$out" 'concluded')"

# --- the three answers are distinguished, not merely counted ----------------
#
# The point of the three cases above stated as one property: the same script,
# handed three answers, produced three different verdicts. A reporter that
# always failed, or always passed, would satisfy one of them and not this.
row completed failure > "$WORK/a.resp"
row completed success > "$WORK/b.resp"
: > "$WORK/c.resp"
run_gate "$WORK/a.resp" >/dev/null; a=$?
run_gate "$WORK/b.resp" >/dev/null; b=$?
run_gate "$WORK/c.resp" >/dev/null; c=$?
check "failing, successful and empty do not all end the same way" "1 0 1" \
	"$a $b $c"

# --- a conclusion that is not success and not failure is reported too -------
#
# `timed_out`, `startup_failure` and `neutral` are still verdicts that say the
# branch is broken. A script that compared against 'failure' rather than
# against 'success' would let them through, and all of them leave the branch
# unverified. (`cancelled` is its own case below: in the schedule path a
# cancelled run only means a newer push superseded it, so the script passes
# it over rather than reporting it.)
for conclusion in timed_out startup_failure neutral; do
	row completed "$conclusion" > "$WORK/other.resp"
	out="$(run_gate "$WORK/other.resp")"; rc=$?
	check "a completed '$conclusion' run is reported" "1" "$rc"
	check "and the message names '$conclusion' rather than guessing" "1" \
		"$(says "$out" "concluded '$conclusion'")"
done

# --- S1: an unsorted page picks the newest by created_at --------------------
#
# Measured 2026-09-08 (Glyndor/apt#249) and 2026-09-17
# (Glyndor/scoop-bucket#173): the API does not always put the newest run at
# the head of a filtered page. The schedule path now reads a 30-item page and
# takes the greatest created_at, so this fixture puts the newer, failing run
# second: the verdict must come from it, not from the older successful run
# that the API happened to list first.
SHA_A="aaaaaaaaaaaa1111111111111111111111111111"
SHA_B="bbbbbbbbbbbb2222222222222222222222222222"
OLD_URL="https://github.com/Glyndor/apt/actions/runs/8000"
NEW_URL="https://github.com/Glyndor/apt/actions/runs/9001"
json_page \
	"$(json_run 8000 8000 completed success "$SHA_A" "$OLD_TS" "$OLD_URL")" \
	"$(json_run 9001 9001 completed failure "$SHA_B" "$NEW_TS" "$NEW_URL")" \
	> "$WORK/s1.json"
out="$(run_gate_json "$WORK/s1.json")"; rc=$?
check "S1: unsorted page, newer failing run second, fails the check" "1" "$rc"
check "S1: and names the newer run's conclusion" "1" \
	"$(says "$out" "concluded 'failure'")"
check "S1: and names the newer run's number (#9001)" "1" \
	"$(says "$out" 'run #9001')"
check "S1: and names the newer run's commit (bbbbbbb)" "1" \
	"$(says "$out" 'bbbbbbb')"
check "S1: and links the newer run" "1" \
	"$(says "$out" 'actions/runs/9001')"
check "S1: and is not the older run's verdict" "0" \
	"$(says "$out" 'actions/runs/8000')"

# --- S2: newest completed run is cancelled, next is success ----------------
#
# A cancelled run only means a newer push superseded it, and the next tick
# will read the newer verdict. The script passes it over and counts how many
# it skipped, so a reader of the log is told that one verdict was not the
# newest by time. The case fails when the run that was cancelled is at the
# head of the page (which the API returns for the most recent runs).
json_page \
	"$(json_run 9001 9001 completed cancelled "$SHA_B" "$NEW_TS" "$NEW_URL")" \
	"$(json_run 9002 9002 completed success "$SHA_B" "$NEW_TS" "$NEW_URL")" \
	> "$WORK/s2.json"
out="$(run_gate_json "$WORK/s2.json")"; rc=$?
check "S2: newest cancelled, next success, passes the check" "0" "$rc"
check "S2: and reports the success run's verdict" "1" \
	"$(says "$out" 'concluded success')"
check "S2: and says exactly 1 cancelled run was passed over" "1" \
	"$(says "$out" 'Passed over 1 cancelled run')"

# --- S3: every completed run is cancelled -----------------------------------
#
# The case where the only thing the API has to say is "nothing happened here
# that anyone cared to keep". This is distinct from an empty page: the API
# returned runs, every one of them was cancelled, and there is no verdict to
# pass through. The contract says fail with a no-verdict message; the
# message must be different from the empty-page one so the reader can tell
# "API had nothing" from "API had nothing of any use".
json_page \
	"$(json_run 9001 9001 completed cancelled "$SHA_B" "$NEW_TS" "$NEW_URL")" \
	"$(json_run 9002 9002 completed cancelled "$SHA_B" "$NEW_TS" "$NEW_URL")" \
	> "$WORK/s3.json"
out="$(run_gate_json "$WORK/s3.json")"; rc=$?
check "S3: every completed run cancelled, fails the check" "1" "$rc"
check "S3: and the message is the no-verdict message" "1" \
	"$(says "$out" 'no verdict from completed runs')"
check "S3: and reports how many were cancelled (2)" "1" \
	"$(says "$out" 'all 2 completed runs were cancelled')"
check "S3: and is not the empty-page message" "0" \
	"$(says "$out" 'no completed run of')"

# --- S4: the schedule-path URL asks for per_page=30 -------------------------
#
# Reading the URL from the log rather than the source: a script that builds
# the URL at runtime can be tested only by what it asked for. The push path
# also uses per_page=30; the schedule path uses status=completed on top of
# it, so this case verifies the schedule filters specifically.
json_page \
	"$(json_run 9001 9001 completed success "$SHA" "$NEW_TS" "$URL")" \
	> "$WORK/s4.json"
run_gate_json "$WORK/s4.json" >/dev/null
check "S4: the schedule URL asks for a 30-item page" "1" \
	"$(logged 'per_page=30')"
check "S4: the schedule URL asks for completed runs only" "1" \
	"$(logged 'status=completed')"
check "S4: the schedule URL asks for the branch it was given" "1" \
	"$(logged "branch=$BRANCH")"
check "S4: the schedule URL targets the right workflow file" "1" \
	"$(logged "workflows/$WF/runs")"
check "S4: the schedule URL targets the repository it was given" "1" \
	"$(logged "repos/$REPO/")"
check "S4: the schedule URL is one call per script run" "1" \
	"$(logged .)"

# --- S5: newest run sits in the MIDDLE of an unsorted page ------------------
#
# S1 puts the newest run second and a wrong choice still has to read two items.
# This case plants three completed runs in the order 10:00 success, 12:00
# failure (the newest), 08:00 success: a script that takes the first item of
# the page sees the 10:00 success and passes, one that takes the last item
# sees the 08:00 success and passes. The only honest answer is the 12:00
# failure in the middle, and the schedule path reaches it by taking the
# greatest created_at across the whole page.
SHA_10="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
SHA_12="cccc2222cccc2222cccc2222cccc2222cccc2222"
SHA_08="eeee3333eeee3333eeee3333eeee3333eeee3333"
URL_10="https://github.com/Glyndor/apt/actions/runs/8100"
URL_12="https://github.com/Glyndor/apt/actions/runs/8200"
URL_08="https://github.com/Glyndor/apt/actions/runs/8300"
TS_10="2026-09-06T10:00:00Z"
TS_12="2026-09-06T12:00:00Z"
TS_08="2026-09-06T08:00:00Z"
json_page \
	"$(json_run 100 100 completed success "$SHA_10" "$TS_10" "$URL_10")" \
	"$(json_run 200 200 completed failure "$SHA_12" "$TS_12" "$URL_12")" \
	"$(json_run 300 300 completed success "$SHA_08" "$TS_08" "$URL_08")" \
	> "$WORK/s5.json"
out="$(run_gate_json "$WORK/s5.json")"; rc=$?
check "S5: unsorted page with newest in the middle, fails the check" "1" "$rc"
check "S5: and names the newest run's conclusion" "1" \
	"$(says "$out" "concluded 'failure'")"
check "S5: and names the newest run's number (#200)" "1" \
	"$(says "$out" 'run #200')"
check "S5: and names the newest run's commit (cccc222)" "1" \
	"$(says "$out" 'cccc222')"
check "S5: and links the newest run" "1" \
	"$(says "$out" 'actions/runs/8200')"
check "S5: and is not the 10:00 run's verdict" "0" \
	"$(says "$out" 'actions/runs/8100')"
check "S5: and is not the 08:00 run's verdict" "0" \
	"$(says "$out" 'actions/runs/8300')"

# --- the URL on the schedule path is not the push URL -----------------------
#
# The two paths share the script but differ in the URL: the push path omits
# the status filter so a run still in flight is visible. A reader of the
# log on a push run can tell which path was taken from the URL alone, which
# is the only way to debug a wrong verdict without re-running the job.
check "schedule URL does not omit status=completed" "1" \
	"$(logged 'status=completed')"

# --- S6: identical created_at, different ids, verdict is the higher id -----
#
# Two runs created in the same second. The API does not promise any order
# inside that second, and a script that compares created_at as a string
# would tie, fall back to page order, and report whatever the API
# happened to list first. The schedule path sorts by created_at then id
# in jq and reverses, so the higher id wins whatever order the page
# arrives in. The page is fed in both orders so a script that only
# looked correct on one of them still has to defend the other.
TIE_TS="2026-09-08T11:14:09Z"
TIE_LO_URL="https://github.com/Glyndor/apt/actions/runs/5000"
TIE_HI_URL="https://github.com/Glyndor/apt/actions/runs/6000"
SHA_TIE_LO="1111111111111111111111111111111111111111"
SHA_TIE_HI="2222222222222222222222222222222222222222"
# Lower id success first, higher id failure second.
json_page \
	"$(json_run 5000 5000 completed success "$SHA_TIE_LO" "$TIE_TS" "$TIE_LO_URL")" \
	"$(json_run 6000 6000 completed failure "$SHA_TIE_HI" "$TIE_TS" "$TIE_HI_URL")" \
	> "$WORK/s6-low-first.json"
out="$(run_gate_json "$WORK/s6-low-first.json")"; rc=$?
check "S6: identical ts, lower id first, verdict is higher id (failure)" "1" "$rc"
check "S6: and names the higher id run's conclusion" "1" \
	"$(says "$out" "concluded 'failure'")"
check "S6: and names the higher id run's number (#6000)" "1" \
	"$(says "$out" 'run #6000')"
check "S6: and is not the lower id run's verdict" "0" \
	"$(says "$out" 'run #5000')"
# Higher id failure first, lower id success second.
json_page \
	"$(json_run 6000 6000 completed failure "$SHA_TIE_HI" "$TIE_TS" "$TIE_HI_URL")" \
	"$(json_run 5000 5000 completed success "$SHA_TIE_LO" "$TIE_TS" "$TIE_LO_URL")" \
	> "$WORK/s6-high-first.json"
out="$(run_gate_json "$WORK/s6-high-first.json")"; rc=$?
check "S6: identical ts, higher id first, verdict is higher id (failure)" "1" "$rc"
check "S6: and names the higher id run's conclusion" "1" \
	"$(says "$out" "concluded 'failure'")"
check "S6: and names the higher id run's number (#6000)" "1" \
	"$(says "$out" 'run #6000')"
check "S6: and is not the lower id run's verdict" "0" \
	"$(says "$out" 'run #5000')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
