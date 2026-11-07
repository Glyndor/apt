#!/usr/bin/env bash
# Behaviour tests for the push path of scripts/monitoring/check-suite-on-main.sh.
#
# GITHUB_EVENT_NAME=push, GITHUB_SHA is the commit that was pushed. The script
# reads a 30-item page, picks the newest run with that head_sha, and polls for
# up to 8 minutes (32 attempts of 15 seconds) when the run is not yet completed.
# A cancelled run for that commit is red.
#
# The push path answers a different question from the cron and pull_request
# path, and it answers it about a different run: the cron path reports the
# newest completed run on the branch, the push path reports the run of the
# commit that was just pushed. A reporter that fell back from one to the other
# would name somebody else's run as the verdict for the push, which is the race
# the push path exists to break. The cron cases are in
# tests/monitoring/suite-on-main/check-suite-on-main-cron.test.sh and the path-independent
# contract is in tests/monitoring/check-suite-on-main.test.sh; the fake `gh`
# both of them use comes from tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
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
# PUSH PATH
#
# GITHUB_EVENT_NAME=push, GITHUB_SHA is the commit that was pushed. The
# script reads a 30-item page, picks the newest run with that head_sha, and
# polls for up to 8 minutes (32 attempts of 15 seconds) when the run is not
# yet completed. A cancelled run for that commit is red.
# ===========================================================================

PUSH_SHA="bbbbbbbbbbbb2222222222222222222222222222"
OTHER_SHA="aaaaaaaaaaaa1111111111111111111111111111"

# --- R1: page has older failing run first, newer successful run second -----
#
# The race that produced the red cross on the fix push on 2026-09-19. The
# previous commit's run was still the most recent COMPLETED run when this
# job asked, so the page holds both. The script must pick the run for
# GITHUB_SHA regardless of where it sits in the page; the test plants the
# older run first and the newer one second to prove the verdict does not
# come from the head of the page.
PUSH_NEW_URL="https://github.com/Glyndor/apt/actions/runs/9501"
PUSH_OLD_URL="https://github.com/Glyndor/apt/actions/runs/9500"
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 9500 9500 completed failure "$OTHER_SHA" "$OLD_TS" "$PUSH_OLD_URL")" \
	"$(json_run 9501 9501 completed success "$PUSH_SHA" "$NEW_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/1"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R1: page with older failing run first, newer successful for head_sha second, passes" "0" "$rc"
check "R1: and names the run for GITHUB_SHA, not the older one" "1" \
	"$(says "$out" 'run #9501')"
check "R1: and the success message names the new commit" "1" \
	"$(says "$out" 'bbbbbbb')"
check "R1: and is not the older run's verdict" "0" \
	"$(says "$out" 'run #9500')"
check "R1: and did not poll, only one call" "1" \
	"$(logged .)"

# --- R2: run for GITHUB_SHA in_progress first, then completed success ------
#
# The job and tests.yml start at the same moment on push, so the run for
# GITHUB_SHA may not have a verdict yet. The script polls once, then reads
# the new verdict on the second call.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 9501 9501 in_progress "" "$PUSH_SHA" "$OLD_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/1"
json_page \
	"$(json_run 9501 9501 completed success "$PUSH_SHA" "$OLD_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/2"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R2: in_progress then completed success, passes" "0" "$rc"
check "R2: and made exactly two API calls" "2" \
	"$(logged .)"
check "R2: and slept exactly once, for 15 seconds" "1" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R2: and the sleep argument was 15" "15" \
	"$(tr '\0' '\n' < "$WORK/sleep.log" | xargs)"

# --- R2b: a transient gh failure on the push path is asked again -------------
# One 502 must not end a poll that has 31 attempts left; a failure that never
# clears must still end red, not green.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 9501 9501 completed success "$PUSH_SHA" "$OLD_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/2"
out="$(STUB_FAIL_FIRST=1 run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R2b: one failing gh call does not end the poll" "0" "$rc"
check "R2b: and it says it is asking again" "1" "$(says "$out" 'asking again')"
out="$(STUB_FAIL_FIRST=99 run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R2b: a failure that never clears ends red" "1" "$rc"

# --- R3: run for GITHUB_SHA completes failure ------------------------------
#
# The push path reads the run for GITHUB_SHA, so a failure on that commit is
# a failure of the push. The message names the run and the commit, so the
# developer pushing the fix can find the verdict without opening the run
# list.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 9501 9501 completed failure "$PUSH_SHA" "$OLD_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/1"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R3: push run completes failure, fails the check" "1" "$rc"
check "R3: and names the conclusion it read" "1" \
	"$(says "$out" "concluded 'failure'")"
check "R3: and names the run for the push commit" "1" \
	"$(says "$out" 'run #9501')"
check "R3: and names the push commit" "1" \
	"$(says "$out" 'bbbbbbb')"
check "R3: and did not poll, only one call" "1" \
	"$(logged .)"

# --- R4: no run for GITHUB_SHA in any of 32 responses -----------------------
#
# The loop polls for 8 minutes (32 attempts of 15 seconds). If none of the
# attempts see a run for the commit, the script must fail with a message
# naming the commit and saying 8 minutes. 32 attempts means 31 sleeps: a
# sleep is between attempts, not after the last one.
#
# The test must plant 32 responses. Doing so by hand would be a 32-line
# fixture, so the helper builds them. The verdict must not name any other
# run's conclusion: a script that fell back to the schedule path would
# happily report someone else's run, which is the exact race this fix
# exists to break.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
for i in $(seq 1 32); do
	# A page that contains runs but NONE for the push commit. The schedule
	# path would happily report the first of these, so the test asserts the
	# message does not name any of their conclusions.
	json_page \
		"$(json_run 9500 9500 completed success "$OTHER_SHA" "$OLD_TS" "$PUSH_OLD_URL")" \
		> "$WORK/json/$i"
done
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R4: no run for GITHUB_SHA in 32 attempts, fails the check" "1" "$rc"
check "R4: and made exactly 32 API calls" "32" \
	"$(logged .)"
check "R4: and slept exactly 31 times" "31" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R4: and every sleep argument was 15" \
	"$(yes 15 | head -31 | tr '\n' ' ' | sed 's/ $//')" \
	"$(tr '\0' '\n' < "$WORK/sleep.log" | xargs)"
check "R4: and the message names the commit (bbbbbbb)" "1" \
	"$(says "$out" 'bbbbbbb')"
check "R4: and the message says 8 minutes" "1" \
	"$(says "$out" '8 minutes')"
check "R4: and does not name any other run's conclusion as the verdict" "0" \
	"$(says "$out" "concluded 'success'")"

# --- R5: run for GITHUB_SHA is cancelled ------------------------------------
#
# In the schedule path a cancelled run is passed over (a newer push
# superseded it). In the push path nothing newer can answer for the commit
# that was pushed, so the run's verdict IS the answer, and a cancelled
# verdict is red. The contract says this explicitly; the test makes it
# explicit too, so a future refactor that treats push like schedule breaks
# here rather than at the next push.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 9501 9501 completed cancelled "$PUSH_SHA" "$OLD_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/1"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R5: push run cancelled, fails the check" "1" "$rc"
check "R5: and names the conclusion it read" "1" \
	"$(says "$out" "concluded 'cancelled'")"
check "R5: and names the run for the push commit" "1" \
	"$(says "$out" 'run #9501')"

# --- R6: older failing run for `a` first, in_progress run for `b` second ---
#
# The race measured on 2026-09-19: when this job asked, the pushed commit's
# tests.yml run was still IN PROGRESS, and the previous commit's run was
# already COMPLETED with `failure`. A reporter that reads the newest
# COMPLETED run on the branch instead of the run for GITHUB_SHA picks the
# older failure and reports it as the verdict for the push. The push path
# must filter by head_sha on the page and poll until the run for the pushed
# commit reaches a verdict.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 100 100 completed failure "$OTHER_SHA" "$OLD_TS" "$PUSH_OLD_URL")" \
	"$(json_run 200 200 in_progress "" "$PUSH_SHA" "$NEW_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/1"
json_page \
	"$(json_run 200 200 completed success "$PUSH_SHA" "$NEW_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/2"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R6: page with older failing run and in_progress for head_sha, passes" "0" "$rc"
check "R6: and made exactly two API calls" "2" \
	"$(logged .)"
check "R6: and slept exactly once, for 15 seconds" "1" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R6: and the sleep argument was 15" "15" \
	"$(tr '\0' '\n' < "$WORK/sleep.log" | xargs)"
check "R6: and names the run for GITHUB_SHA (id 200)" "1" \
	"$(says "$out" 'run #200')"
check "R6: and does not name the older run's id (100)" "0" \
	"$(says "$out" 'run #100')"
check "R6: and does not report the older run as red main" "0" \
	"$(says "$out" 'main is red')"

# --- R8: identical created_at, different ids, verdict is the higher id -----
#
# Same race as S6, but on the push path. Two runs for GITHUB_SHA created
# in the same second: a script that only compared created_at would tie,
# fall back to page order, and pick whatever the API happened to list
# first. The push path sorts by created_at then id and reverses, then
# takes the first row, so the higher id wins whatever order the page
# arrives in. The page is fed in both orders so a script that only
# looked correct on one of them still has to defend the other.
PUSH_TIE_TS="2026-09-08T11:14:09Z"
PUSH_TIE_LO_URL="https://github.com/Glyndor/apt/actions/runs/7000"
PUSH_TIE_HI_URL="https://github.com/Glyndor/apt/actions/runs/7100"
# Lower id success first, higher id failure second.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 7000 7000 completed success "$PUSH_SHA" "$PUSH_TIE_TS" "$PUSH_TIE_LO_URL")" \
	"$(json_run 7100 7100 completed failure "$PUSH_SHA" "$PUSH_TIE_TS" "$PUSH_TIE_HI_URL")" \
	> "$WORK/json/1"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R8: push identical ts, lower id first, verdict is higher id (failure)" "1" "$rc"
check "R8: and names the higher id run's conclusion" "1" \
	"$(says "$out" "concluded 'failure'")"
check "R8: and names the higher id run's number (#7100)" "1" \
	"$(says "$out" 'run #7100')"
check "R8: and is not the lower id run's verdict" "0" \
	"$(says "$out" 'run #7000')"
# Higher id failure first, lower id success second.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 7100 7100 completed failure "$PUSH_SHA" "$PUSH_TIE_TS" "$PUSH_TIE_HI_URL")" \
	"$(json_run 7000 7000 completed success "$PUSH_SHA" "$PUSH_TIE_TS" "$PUSH_TIE_LO_URL")" \
	> "$WORK/json/1"
out="$(run_gate_json_dir push "$PUSH_SHA")"; rc=$?
check "R8: push identical ts, higher id first, verdict is higher id (failure)" "1" "$rc"
check "R8: and names the higher id run's conclusion" "1" \
	"$(says "$out" "concluded 'failure'")"
check "R8: and names the higher id run's number (#7100)" "1" \
	"$(says "$out" 'run #7100')"
check "R8: and is not the lower id run's verdict" "0" \
	"$(says "$out" 'run #7000')"

# --- R7: push with empty GITHUB_SHA refuses rather than falls back ---------
#
# A push event without a commit SHA would otherwise fall through to the
# schedule path, which answers the question for the newest run on the
# branch, not the run for the push that just landed. That is a verdict
# for a different commit, and the contract says refuse with a clear
# ::error:: and a non-zero exit before any API call is made.
out="$(GITHUB_EVENT_NAME=push GITHUB_SHA='' run_gate_json_dir push '')"; rc=$?
check "R7: push with empty GITHUB_SHA fails the check" "1" "$rc"
check "R7: and prints an ::error:: line" "1" \
	"$(says "$out" '::error::')"
check "R7: and the message says GITHUB_SHA is empty" "1" \
	"$(says "$out" 'GITHUB_SHA is empty')"
check "R7: and did not call gh (no fallback to schedule)" "0" \
	"$(logged .)"

# --- the push URL filters by head_sha and not by status ---------------------
#
# Reading the URL from the log: the push path asks for a 30-item page on
# the branch narrowed to the pushed commit by `head_sha=`, and keeps the
# jq select as a second guard for a listing that did not honour the
# filter. The status filter is omitted on purpose, so a run still in
# flight is visible to the next attempt.
rm -rf "$WORK/json"; mkdir -p "$WORK/json"
json_page \
	"$(json_run 9501 9501 completed success "$PUSH_SHA" "$OLD_TS" "$PUSH_NEW_URL")" \
	> "$WORK/json/1"
run_gate_json_dir push "$PUSH_SHA" >/dev/null
check "the push URL asks for a 30-item page" "1" "$(logged 'per_page=30')"
check "the push URL asks for the branch it was given" "1" \
	"$(logged "branch=$BRANCH")"
check "the push URL asks for the head_sha of the pushed commit" "1" \
	"$(logged "head_sha=$PUSH_SHA")"
check "the push URL targets the right workflow file" "1" \
	"$(logged "workflows/$WF/runs")"
check "the push URL targets the repository it was given" "1" \
	"$(logged "repos/$REPO/")"
check "and the push URL does NOT filter by status=completed" "0" \
	"$(logged 'status=completed')"
check "and the push URL does NOT filter by status=success either" "0" \
	"$(logged 'status=success')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
