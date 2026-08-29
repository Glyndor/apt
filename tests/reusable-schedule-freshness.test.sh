#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-schedule-freshness.yml.
#
# A cron that stops firing emits nothing at all, and "no alert" is
# indistinguishable from "all clear." This gate turns that silence into a
# red check on ordinary work, by treating the newest successful scheduled
# run as evidence the cron is alive, and failing when that signal is too
# old or absent.
#
# The step depends on GH_TOKEN, REPO, WORKFLOW, and MAX_AGE_DAYS from the
# environment; the only network call is a single `gh api ... --jq ...`. A
# fake `gh` on PATH records the URL it was called with and serves a canned
# response, so the cases below exercise the real shell with a deterministic
# API rather than mocking the workflow itself.
#
# Requires: python3, GNU date (for `date -u -d`).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Pull one step's `run:` body out of a workflow, dedented, so it can be run.
# Same helper as tests/reusable-dco.test.sh: the point is to exercise the
# shell as it ships rather than a copy of it that can drift.
step_script() { # $1=workflow path  $2=step name substring
	python3 - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if not line.strip():
        body.append("")
        continue
    if not line.startswith(" " * 10):
        break
    body.append(line[10:])
print("\n".join(body))
PY
}

# Fake `gh`. Appends its argv (NUL-separated) to STUB_LOG and prints line 1
# of STUB_RESPONSES — there is only ever one call per step run, but a
# responses file makes the contract the same as the dependabot stub so the
# two tests stay symmetrical. An empty line is exactly what
# `gh --jq '... // empty'` produces when nothing matched.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
RESP="${STUB_RESPONSES:?stub responses file required}"
idx=$(grep -cz . "$LOG" 2>/dev/null || true)
idx="${idx:-0}"
idx=$((idx + 1))
printf '%s\0' "$*" >> "$LOG"
val=$(awk -v n="$idx" 'NR==n {print; exit}' "$RESP")
printf '%s' "$val"
exit "${STUB_EXIT_CODE:-0}"
STUB
	chmod +x "$WORK/bin/gh"
}

WORKFLOW="$HERE/.github/workflows/reusable-schedule-freshness.yml"
step_script "$WORKFLOW" "Check the newest successful scheduled run" > "$WORK/step.sh"
write_stub

REPO="owner/repo"
WF="audit.yml"
MAX_AGE_DAYS=10

# Build an ISO timestamp N days before now. `date -u -d "N days ago"` is
# exactly N * 86400 seconds earlier -- UTC has no daylight saving, so crossing
# midnight or a month boundary changes nothing -- and setup and run are seconds
# apart, so `age_days` is N and not N+1. Measured, not assumed.
ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }

# Run the step with the stub on PATH. Combined stdout+stderr in `out`, exit
# code in `rc`. The stub log is reset per call so each case starts at index 1.
run_step() { # $1=MAX_AGE_DAYS  $2=responses file
	local max="$1" resp="$2"
	rm -f "$WORK/gh.log"
	STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$resp" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" MAX_AGE_DAYS="$max" \
	bash "$WORK/step.sh" 2>&1
}

# --- a recent successful run passes -------------------------------------

printf '%s\n' "$(ago 1)" > "$WORK/recent.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/recent.resp")"; rc=$?
check "a 1-day-old successful run passes" "0" "$rc"
check "and the success line reports the computed age" "1" \
	"$(printf '%s' "$out" | grep -q '(1d ago)' && echo 1 || echo 0)"
check "and names the workflow it checked" "1" \
	"$(printf '%s' "$out" | grep -q "$WF" && echo 1 || echo 0)"

# --- an old run fails, naming the workflow and the age ------------------

printf '%s\n' "$(ago 11)" > "$WORK/old.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp")"; rc=$?
check "an 11-day-old run fails the 10-day limit" "1" "$rc"
check "and the error names the workflow file (audit.yml)" "1" \
	"$(printf '%s' "$out" | grep -q "$WF last succeeded" && echo 1 || echo 0)"
check "and the error names the age it measured (11 days)" "1" \
	"$(printf '%s' "$out" | grep -q '11 days ago' && echo 1 || echo 0)"
check "and is not the empty-result error" "0" \
	"$(printf '%s' "$out" | grep -c 'No successful scheduled run')"

# --- an empty result fails with the empty-result error ------------------

printf '\n' > "$WORK/empty.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/empty.resp")"; rc=$?
check "no successful run on record fails" "1" "$rc"
check "and the error says 'No successful scheduled run'" "1" \
	"$(printf '%s' "$out" | grep -q 'No successful scheduled run' && echo 1 || echo 0)"
check "and names the workflow file (audit.yml)" "1" \
	"$(printf '%s' "$out" | grep -q "No successful scheduled run on record for ${WF}" && echo 1 || echo 0)"
check "and is not the too-old error" "0" \
	"$(printf '%s' "$out" | grep -c 'over the 10-day limit')"

# --- the URL filters by event=schedule AND status=success ---------------
#
# Without those two filters, the gate would happily report a *failed* run as
# evidence the cron is alive, which is the exact failure this gate exists to
# catch. So both substrings must appear in the URL the step actually built.

printf '%s\n' "$(ago 1)" > "$WORK/url.resp"
run_step "$MAX_AGE_DAYS" "$WORK/url.resp" >/dev/null
check "the URL the step built contains event=schedule" "1" \
	"$(grep -acz 'event=schedule' "$WORK/gh.log" | tr -d ' ')"
check "the URL the step built contains status=success" "1" \
	"$(grep -acz 'status=success' "$WORK/gh.log" | tr -d ' ')"
check "the URL targets the right workflow file" "1" \
	"$(grep -acz "workflows/${WF}/runs" "$WORK/gh.log" | tr -d ' ')"
check "and it made exactly one API call (no paging here)" "1" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"

# --- boundary: exactly MAX_AGE_DAYS days old PASSES (the comparison is -gt)

printf '%s\n' "$(ago "$MAX_AGE_DAYS")" > "$WORK/boundary.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/boundary.resp")"; rc=$?
check "exactly MAX_AGE_DAYS days old passes (the comparison is -gt, not -ge)" "0" "$rc"

# --- a failing `gh` must fail the step ----------------------------------
#
# `set -euo pipefail` is supposed to carry a non-zero `gh` through, so an API
# error stops the job rather than being read as "no result", which would be
# reported as a dead schedule and send someone looking for the wrong thing.

printf '%s\n' "$(ago 1)" > "$WORK/apifail.resp"
out="$(STUB_EXIT_CODE=1 run_step "$MAX_AGE_DAYS" "$WORK/apifail.resp")"
rc=$?
check "a failing gh api call fails the step" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and does not report it as a missing schedule" "0" \
	"$(printf '%s' "$out" | grep -c 'No successful scheduled run')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
