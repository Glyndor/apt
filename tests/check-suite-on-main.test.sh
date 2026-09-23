#!/usr/bin/env bash
# Behaviour tests for scripts/check-suite-on-main.sh.
#
# The script's failure mode is not a crash, it is agreement. A reporter that
# reads the wrong field, asks for the wrong runs, or walks past an empty history
# prints the same green line as one that did the work, and green is exactly what
# nobody questions. So the cases below plant each answer and require the script
# to tell them apart: a completed failing run must be reported, a completed
# successful one must be silent, and an empty history must say it found nothing
# rather than pass.
#
# The script branches on GITHUB_EVENT_NAME. On push it reads the run for the
# commit that was pushed (GITHUB_SHA), polls until that run finishes or eight
# minutes elapse, and a cancelled run for that commit is red. On schedule and
# pull_request it reads a 30-item page of completed runs and takes the
# greatest created_at, skipping cancelled runs and counting how many it
# skipped. Both branches share the same script and the same fake `gh` on PATH.
#
# The script's one dependency on the outside world is `gh`. A fake `gh` on PATH
# records the URL it was called with and serves a canned response, so the real
# shell runs against a deterministic API and no case here touches the network.
# The same stub contract is used here as in tests/reusable-schedule-freshness.test.sh,
# kept deliberately identical so the two read as one idea.
#
# Requires: bash, jq, GNU coreutils.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/check-suite-on-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# The stub log holds one NUL-separated record per call, so it is read with grep
# rather than through a variable: command substitution drops NUL bytes and warns
# about it, which would put noise in the middle of the results.
logged() { # $1=pattern
	grep -aczF -- "$1" "$WORK/gh.log" | tr -d ' '
}

# Nth call's URL from the stub log, for assertions on the URL the script built
# at a particular step in a loop. awk reads the NUL-separated log and prints
# the Nth record; a missing N is empty.
url_call() { # $1=call-number
	awk -v RS='\0' -v n="$1" 'NR==n {print; exit}' "$WORK/gh.log"
}

# Fake `gh` and `sleep`. The gh stub appends its argv NUL-separated to STUB_LOG
# and serves a response. Three response modes:
#
#   * STUB_RESPONSE: one pre-formatted line, served on every call (the legacy
#     mode, used for the cases that do not need JSON);
#   * STUB_JSON: one JSON file, served on every call, with the script's own
#     --jq filter applied via real jq (used when every call gets the same
#     response);
#   * STUB_JSON_DIR: a directory whose file N is the JSON response for the Nth
#     call, with the script's --jq filter applied. The push path polls in a
#     loop, so each case plants the responses it wants call by call.
#
# The sleep stub appends its argv to SLEEP_LOG and returns at once, so the
# eight-minute push poll runs in milliseconds.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
printf '%s\0' "$*" >> "$LOG"
filter=""; prev=""
for arg in "$@"; do
	[ "$prev" = "--jq" ] && filter="$arg"
	prev="$arg"
done
if [ -n "${STUB_JSON_DIR:-}" ]; then
	idx=$(grep -cz . "$LOG" 2>/dev/null || true)
	idx="${idx:-0}"
	f="${STUB_JSON_DIR}/${idx}"
	[ -f "$f" ] || { echo "stub: no response file for call ${idx} (${f})" >&2; exit 1; }
	if [ -n "$filter" ]; then
		jq -r "$filter" "$f"
	else
		cat "$f"
	fi
	exit "${STUB_EXIT_CODE:-0}"
fi
if [ -n "${STUB_JSON:-}" ]; then
	if [ -n "$filter" ]; then
		jq -r "$filter" "${STUB_JSON}"
	else
		cat "${STUB_JSON}"
	fi
	exit "${STUB_EXIT_CODE:-0}"
fi
RESP="${STUB_RESPONSE:?stub response file required}"
cat "$RESP"
exit "${STUB_EXIT_CODE:-0}"
STUB
	chmod +x "$WORK/bin/gh"
	cat > "$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$*" >> "${SLEEP_LOG:?sleep log path required}"
STUB
	chmod +x "$WORK/bin/sleep"
}
write_stub

REPO="Glyndor/apt"
WF="tests.yml"
BRANCH="main"

# One run of the script with the stub on PATH. Combined stdout and stderr in
# `out`, exit code in `rc`. The stub logs are reset per call so each case
# counts its own API calls and sleeps. Optional GITHUB_EVENT_NAME and
# GITHUB_SHA select the push path; default is schedule/pull_request.
run_gate() { # $1=response file  $2=event (optional)  $3=sha (optional)
	local resp="$1" event="${2:-}" sha="${3:-}"
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: > "$WORK/gh.log"
	: > "$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" SLEEP_LOG="$WORK/sleep.log" STUB_RESPONSE="$resp" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy \
	GITHUB_EVENT_NAME="$event" GITHUB_SHA="$sha" \
	"$GATE" "$REPO" "$WF" "$BRANCH" 2>&1
}

# Like run_gate but uses STUB_JSON (one response for every call). The
# schedule-path cases that need only one call use this.
run_gate_json() { # $1=JSON file  $2=event (optional)  $3=sha (optional)
	local json="$1" event="${2:-}" sha="${3:-}"
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: > "$WORK/gh.log"
	: > "$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" SLEEP_LOG="$WORK/sleep.log" STUB_JSON="$json" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy \
	GITHUB_EVENT_NAME="$event" GITHUB_SHA="$sha" \
	"$GATE" "$REPO" "$WF" "$BRANCH" 2>&1
}

# Like run_gate but plants JSON responses per call in $WORK/json/. The
# push-path loop calls gh once per attempt, so this is what the push cases
# use.
run_gate_json_dir() { # $1=event  $2=sha
	local event="$1" sha="$2"
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: > "$WORK/gh.log"
	: > "$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" SLEEP_LOG="$WORK/sleep.log" STUB_JSON_DIR="$WORK/json" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy \
	GITHUB_EVENT_NAME="$event" GITHUB_SHA="$sha" \
	"$GATE" "$REPO" "$WF" "$BRANCH" 2>&1
}

# A TSV row in the shape the schedule-path jq filter emits: status,
# conclusion, run number, head sha, created_at, html_url. The number, sha and
# URL are fixed so a case can require the message to carry the run it read
# rather than a plausible one. The legacy STUB_RESPONSE mode feeds these
# lines to the script.
SHA="4f1c0d9a2b3c4d5e6f708192a3b4c5d6e7f80912"
URL="https://github.com/Glyndor/apt/actions/runs/9001"
CREATED="2026-09-06T19:32:11Z"
row() { # $1=status $2=conclusion
	printf '%s\t%s\t314\t%s\t%s\t%s\n' \
		"$1" "$2" "$SHA" "$CREATED" "$URL"
}

# A JSON workflow_runs row. The script reads head_sha, status, conclusion,
# run_number, created_at and html_url from each run; other fields are kept
# here so a future reader sees what the page looks like in the wild.
json_run() { # $1=id  $2=run_number  $3=status  $4=conclusion  $5=head_sha  $6=created_at  $7=html_url
	cat <<JSON
{"id":$1,"run_number":$2,"status":"$3","conclusion":"$4","head_sha":"$5","created_at":"$6","html_url":"$7"}
JSON
}

# A JSON page wrapping a workflow_runs array.
json_page() {
	printf '{"workflow_runs":['
	local sep=""
	for r in "$@"; do
		printf '%s%s' "$sep" "$r"
		sep=","
	done
	printf ']}\n'
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
OLD_TS="2026-09-06T19:32:11Z"
NEW_TS="2026-09-08T11:14:09Z"
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

# ===========================================================================
# SHARED CASES
#
# Behaviors that apply regardless of GITHUB_EVENT_NAME.
# ===========================================================================

# --- the branch is an argument, not a constant ------------------------------
#
# The job passes main, and the script must not have main baked in: a copy of
# this check pointed at a release branch has to read that branch.
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
	"$(says "$(uncommented "$FRESHNESS")" 'scripts/check-suite-on-main.sh')"
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
