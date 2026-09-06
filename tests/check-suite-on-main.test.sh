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
# The script's one dependency on the outside world is `gh`. A fake `gh` on PATH
# records the URL it was called with and serves a canned line, so the real shell
# runs against a deterministic API and no case here touches the network. That is
# the same stub contract as tests/reusable-schedule-freshness.test.sh, kept
# deliberately identical so the two read as one idea.
#
# Requires: nothing beyond coreutils and grep.
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
	grep -acz -- "$1" "$WORK/gh.log" | tr -d ' '
}

# Fake `gh`. Appends its argv to STUB_LOG and prints STUB_RESPONSE verbatim,
# which is the tab-separated line the real `gh api --jq ... | @tsv` produces.
# An empty file is exactly what `--jq '... // empty'` yields when the run list
# came back empty.
#
# The argv is recorded NUL-separated, because the jq filter it carries spans
# several lines: counted by line, one call would read as four and the
# "exactly one API call" case below would pass while measuring nothing.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
RESP="${STUB_RESPONSE:?stub response file required}"
printf '%s\0' "$*" >> "$LOG"
cat "$RESP"
exit "${STUB_EXIT_CODE:-0}"
STUB
	chmod +x "$WORK/bin/gh"
}
write_stub

REPO="Glyndor/apt"
WF="tests.yml"
BRANCH="main"

# One run of the script with the stub on PATH. Combined stdout and stderr in
# `out`, exit code in `rc`, the stub log reset per call so each case counts its
# own API calls.
run_gate() { # $1=response file
	rm -f "$WORK/gh.log"
	: > "$WORK/gh.log"
	STUB_LOG="$WORK/gh.log" STUB_RESPONSE="$1" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy \
	"$GATE" "$REPO" "$WF" "$BRANCH" 2>&1
}

# A row in the shape the jq filter emits: status, conclusion, run number, head
# sha, created_at, html_url. The number, sha and URL are fixed, so a case can
# require the message to carry the run it read rather than a plausible one.
SHA="4f1c0d9a2b3c4d5e6f708192a3b4c5d6e7f80912"
URL="https://github.com/Glyndor/apt/actions/runs/9001"
CREATED="2026-09-06T19:32:11Z"
row() { # $1=status $2=conclusion
	printf '%s\t%s\t314\t%s\t%s\t%s\n' \
		"$1" "$2" "$SHA" "$CREATED" "$URL"
}

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
# `cancelled` and `timed_out` are the absence of evidence, not evidence that
# main passes. A script that compared against 'failure' rather than against
# 'success' would let both through, and both leave the branch unverified.
for conclusion in cancelled timed_out startup_failure neutral; do
	row completed "$conclusion" > "$WORK/other.resp"
	out="$(run_gate "$WORK/other.resp")"; rc=$?
	check "a completed '$conclusion' run is reported" "1" "$rc"
	check "and the message names '$conclusion' rather than guessing" "1" \
		"$(says "$out" "concluded '$conclusion'")"
done

# --- a run still in flight is not a failure ---------------------------------
#
# Two mechanisms, and the test requires both. The request filters by
# status=completed, so the API never offers a run in flight; and if that filter
# were dropped, the guard in the script must not read a run with no conclusion
# as a broken branch. Reporting an ordinary two-minute merge window as red is
# how a check earns the habit of being clicked past.

row in_progress "" > "$WORK/inflight.resp"
out="$(run_gate "$WORK/inflight.resp")"; rc=$?
check "a run that is not completed is not reported as a red branch" "0" \
	"$(says "$out" 'concluded')"
check "and is named as a fault in the query instead" "1" \
	"$(says "$out" "status 'in_progress', not 'completed'")"
check "and still exits non-zero, because nothing was measured" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- the URL asks for the right runs ----------------------------------------
#
# Every case above is served by a stub, so the filters are only correct if the
# URL carries them. status=completed is what skips a run in flight; branch=main
# is what makes this the state of main rather than of somebody's topic branch;
# per_page=1 with the API's newest-first order is what makes it the newest.

row completed success > "$WORK/url.resp"
run_gate "$WORK/url.resp" >/dev/null
check "the URL asks for completed runs only" "1" "$(logged 'status=completed')"
check "the URL asks for the branch it was given" "1" "$(logged "branch=$BRANCH")"
check "the URL asks for one run, the newest" "1" "$(logged 'per_page=1')"
check "the URL targets the right workflow file" "1" \
	"$(logged "workflows/$WF/runs")"
check "the URL targets the repository it was given" "1" \
	"$(logged "repos/$REPO/")"
check "and it made exactly one API call" "1" "$(logged .)"

# --- the branch is an argument, not a constant ------------------------------
#
# The job passes main, and the script must not have main baked in: a copy of
# this check pointed at a release branch has to read that branch.
rm -f "$WORK/gh.log"; : > "$WORK/gh.log"
STUB_LOG="$WORK/gh.log" STUB_RESPONSE="$WORK/url.resp" \
	PATH="$WORK/bin:$PATH" GH_TOKEN=dummy \
	"$GATE" "$REPO" "$WF" release >/dev/null 2>&1
check "a branch other than main reaches the URL" "1" "$(logged 'branch=release')"

# --- the branch defaults to main --------------------------------------------
rm -f "$WORK/gh.log"; : > "$WORK/gh.log"
STUB_LOG="$WORK/gh.log" STUB_RESPONSE="$WORK/url.resp" \
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
[ "$fail" -eq 0 ]
