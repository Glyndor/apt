#!/usr/bin/env bash
#
# The shared fixture for the check-suite-on-main suites.
#
# It is sourced, not executed: it installs the fake `gh` and the fake `sleep`
# on PATH, the builders for the API answers, the constants both paths read and
# the trap that removes the work directory. It asserts nothing and prints no
# sentinel, because it is not a suite.
#
# Three suites source it:
#
#   tests/monitoring/check-suite-on-main-cron.test.sh  the cron and pull_request path
#   tests/monitoring/check-suite-on-main-push.test.sh  the push path
#   tests/monitoring/check-suite-on-main.test.sh       the path-independent contract
#
# The script's one dependency on the outside world is `gh`. A fake `gh` on PATH
# records the URL it was called with and serves a canned response, so the real
# shell runs against a deterministic API and no case that sources this file
# touches the network. The same stub contract is used here as in
# tests/ci/reusable/reusable-schedule-freshness.test.sh, kept deliberately
# identical so the two read as one idea.
#
# Requires: bash, jq, GNU coreutils.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="$HERE/scripts/monitoring/check-suite-on-main.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="Glyndor/apt"
WF="tests.yml"
BRANCH="main"

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
	# STUB_FAIL_FIRST=N: the first N calls fail like a 502.
	if [ "$idx" -le "${STUB_FAIL_FIRST:-0}" ]; then
		echo "gh: HTTP 502" >&2
		exit 1
	fi
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

# The two timestamps both paths order their pages by. The schedule path takes
# the greatest created_at on the page; the push path sorts by created_at then
# id and reverses.
# shellcheck disable=SC2034  # read by the suites that source this file
OLD_TS="2026-09-06T19:32:11Z"
# shellcheck disable=SC2034  # read by the suites that source this file
NEW_TS="2026-09-08T11:14:09Z"
