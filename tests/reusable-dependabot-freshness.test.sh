#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-dependabot-freshness.yml.
#
# Dependabot is an integration, not a workflow: a silent Dependabot emits
# nothing, and "all up to date" looks identical to "Dependabot is dead." This
# gate turns that silence into a red check on ordinary work, by treating the
# newest Dependabot-authored pull request as the last time the integration
# spoke, and failing when that signal is too old or absent.
#
# The step depends on GH_TOKEN, REPO, and MAX_AGE_DAYS from the environment;
# the only network call is `gh api ... --jq ...`, paginated over three pages.
# A fake `gh` on PATH records each URL it was called with and serves a per-call
# canned response, so the cases below exercise the real shell with a
# deterministic API rather than mocking the workflow itself.
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

# Fake `gh`. Appends its argv (NUL-separated) to STUB_LOG and prints line
# `call_index` of STUB_RESPONSES. An empty line is exactly what
# `gh --jq '... // empty'` produces when nothing matched: the step keys off
# `[ -n "$latest" ]` to decide the page was empty.
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

WORKFLOW="$HERE/.github/workflows/reusable-dependabot-freshness.yml"
step_script "$WORKFLOW" "Check the newest Dependabot pull request" > "$WORK/step.sh"
write_stub

REPO="owner/repo"
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
	GH_TOKEN=dummy REPO="$REPO" MAX_AGE_DAYS="$max" \
	bash "$WORK/step.sh" 2>&1
}

# Count how many times the stub was called: number of NUL-terminated records
# in the log.
call_count() { grep -cz . "$WORK/gh.log" 2>/dev/null || echo 0; }

# --- a recent timestamp passes and reports its age ------------------------

printf '%s\n' "$(ago 1)" > "$WORK/recent.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/recent.resp")"; rc=$?
check "a 1-day-old Dependabot PR passes" "0" "$rc"
check "and the success line reports the computed age" "1" \
	"$(printf '%s' "$out" | grep -q '(1d ago)' && echo 1 || echo 0)"
check "and it asked for the first page only" "1" \
	"$(grep -cz 'page=1' "$WORK/gh.log" | tr -d ' ')"
check "and stopped after one call (paging stops at the first hit)" "1" \
	"$(call_count | tr -d ' ')"

# --- an old timestamp fails and names its age ----------------------------

printf '%s\n' "$(ago 11)" > "$WORK/old.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp")"; rc=$?
check "an 11-day-old PR fails the 10-day limit" "1" "$rc"
check "and the error names the age it measured (11 days)" "1" \
	"$(printf '%s' "$out" | grep -q '11 days ago' && echo 1 || echo 0)"
check "and names the limit in the same line" "1" \
	"$(printf '%s' "$out" | grep -q 'over the 10-day limit' && echo 1 || echo 0)"
check "and is not the empty-result error" "0" \
	"$(printf '%s' "$out" | grep -c 'No Dependabot pull request')"

# --- all three pages empty: the empty-result error fires ----------------

printf '\n\n\n' > "$WORK/empty.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/empty.resp")"; rc=$?
check "no Dependabot PR on any page fails" "1" "$rc"
check "and the error says 'No Dependabot pull request'" "1" \
	"$(printf '%s' "$out" | grep -q 'No Dependabot pull request' && echo 1 || echo 0)"
check "and names how many pull requests it looked through (300 = 3 * 100)" "1" \
	"$(printf '%s' "$out" | grep -q 'in the newest 300' && echo 1 || echo 0)"
check "and is not the too-old error" "0" \
	"$(printf '%s' "$out" | grep -c 'over the 10-day limit')"
check "and paged through all three pages" "3" "$(call_count | tr -d ' ')"

# --- paging stops at the first page that answers ------------------------

printf '%s\n\n\n' "$(ago 1)" > "$WORK/p1.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/p1.resp")"; rc=$?
check "when page 1 answers, the loop makes exactly one API call" "1" \
	"$(call_count | tr -d ' ')"
check "and that call asked for page=1, not page=2 or page=3" "0" \
	"$(grep -cz 'page=2' "$WORK/gh.log" | tr -d ' ')"
check "and it asked the right endpoint" "1" \
	"$(grep -cz "repos/${REPO}/pulls?state=all" "$WORK/gh.log" | tr -d ' ')"

# --- paging tries all three pages when each returns nothing -------------

printf '\n\n\n' > "$WORK/threeempty.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/threeempty.resp")"; rc=$?
check "when each page is empty, the loop makes three API calls" "3" \
	"$(call_count | tr -d ' ')"
check "and the pages were 1, 2, 3 in order" "3" \
	"$(grep -aoE 'page=[123]' "$WORK/gh.log" | sort -u | wc -l | tr -d ' ')"

# --- boundary: exactly MAX_AGE_DAYS days old PASSES (the comparison is -gt)

printf '%s\n' "$(ago "$MAX_AGE_DAYS")" > "$WORK/boundary.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/boundary.resp")"; rc=$?
check "exactly MAX_AGE_DAYS days old passes (the comparison is -gt, not -ge)" "0" "$rc"

# --- a failing `gh` must fail the step ----------------------------------
#
# `set -euo pipefail` is supposed to carry a non-zero `gh` through. Without
# that, an API error is indistinguishable from an empty page, and the loop
# would walk all three and then report that Dependabot has never run here.

printf '%s\n' "$(ago 1)" > "$WORK/apifail.resp"
out="$(STUB_EXIT_CODE=1 run_step "$MAX_AGE_DAYS" "$WORK/apifail.resp")"
rc=$?
check "a failing gh api call fails the step" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and does not report it as Dependabot never having run" "0" \
	"$(printf '%s' "$out" | grep -c 'No Dependabot pull request')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
