#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-dependabot-freshness.yml.
#
# Dependabot is an integration, not a workflow: a silent Dependabot emits
# nothing, and "all up to date" looks identical to "Dependabot is dead." This
# gate turns that silence into a red check on ordinary work, by treating the
# newest Dependabot-authored pull request as the last time the integration
# spoke, and failing when that signal is too old or absent.
#
# The step depends on GH_TOKEN, REPO, MAX_AGE_DAYS and WORKFLOWS_DIR from the
# environment. Two network calls exist: `gh api ... --jq ...`, paginated over
# three pages, and `git ls-remote --tags` against each pinned action's upstream,
# asked only once the newest pull request is over the limit. A fake `gh` on
# PATH records each URL it was called with and serves a per-call canned
# response; a fake `git` serves canned tag lists per repository and records
# that it was asked. The cases below exercise the real shell with a
# deterministic API rather than mocking the workflow itself.
#
# Silence is only an alarm when there was something to say: over the limit
# with every pin at its newest upstream tag passes. The default fixture below
# therefore pins one action BEHIND upstream, so the pre-existing "too old
# fails" cases keep meaning what they meant, and the cases at the end vary the
# fixture.
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

# Fake `git`. `ls-remote --tags --refs https://github.com/<owner>/<repo> ...`
# prints the file "$STUB_TAGS_DIR/<owner>__<repo>" (refs/tags lines, one per
# tag) and records the repository asked in STUB_GIT_LOG; an absent file is an
# unreadable upstream (exit 128, nothing printed), which is what a network
# failure or a renamed repository looks like. Anything else falls through to
# the real git, which the step never calls.
write_git_stub() {
	cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "ls-remote" ]; then
	repo=""
	for a in "$@"; do case "$a" in https://github.com/*) repo="${a#https://github.com/}" ;; esac; done
	printf '%s\0' "$repo" >> "${STUB_GIT_LOG:?}"
	f="${STUB_TAGS_DIR:?}/${repo//\//__}"
	[ -f "$f" ] || exit 128
	cat "$f"
	exit 0
fi
exec /usr/bin/git "$@"
STUB
	chmod +x "$WORK/bin/git"
}

# A workflows directory pinning the given actions. Each argument is
# "owner/repo vX.Y.Z"; the SHA is a placeholder, the step never resolves it.
fixture() { # $1=dir  $2..=pins
	local dir="$1"; shift
	rm -rf "$dir"; mkdir -p "$dir"
	{
		echo "jobs:"
		echo "  t:"
		echo "    steps:"
		for pin in "$@"; do
			echo "      - uses: ${pin% *}@0000000000000000000000000000000000000000 # ${pin#* }"
		done
	} > "$dir/ci.yml"
}

# Upstream serves these tags for a repository.
upstream() { # $1=owner/repo  $2..=tags
	local repo="$1"; shift
	mkdir -p "$WORK/tags"
	printf '' > "$WORK/tags/${repo//\//__}"
	for t in "$@"; do
		echo "0000000000000000000000000000000000000000	refs/tags/$t" >> "$WORK/tags/${repo//\//__}"
	done
}

WORKFLOW="$HERE/.github/workflows/reusable-dependabot-freshness.yml"
step_script "$WORKFLOW" "Check the newest Dependabot pull request" > "$WORK/step.sh"
write_stub
write_git_stub

# The default fixture: one pin behind upstream, so an over-the-limit silence is
# the alarm it used to be. Cases that want every pin current build their own.
fixture "$WORK/wf" "actions/checkout v7.0.0"
upstream actions/checkout v7.0.0 v7.0.1

REPO="owner/repo"
MAX_AGE_DAYS=10

# Build an ISO timestamp N days before now. `date -u -d "N days ago"` is
# exactly N * 86400 seconds earlier -- UTC has no daylight saving, so crossing
# midnight or a month boundary changes nothing -- and setup and run are seconds
# apart, so `age_days` is N and not N+1. Measured, not assumed.
ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }

# Run the step with the stub on PATH. Combined stdout+stderr in `out`, exit
# code in `rc`. The stub log is reset per call so each case starts at index 1.
run_step() { # $1=MAX_AGE_DAYS  $2=responses file  [$3=workflows dir]
	local max="$1" resp="$2" wf="${3:-$WORK/wf}"
	rm -f "$WORK/gh.log" "$WORK/git.log"
	STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$resp" \
	STUB_GIT_LOG="$WORK/git.log" STUB_TAGS_DIR="$WORK/tags" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy REPO="$REPO" MAX_AGE_DAYS="$max" WORKFLOWS_DIR="$wf" \
	bash "$WORK/step.sh" 2>&1
}

# How many repositories the step asked upstream about.
git_calls() { grep -cz . "$WORK/git.log" 2>/dev/null || echo 0; }

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

# --- silence is only an alarm when there was something to say --------------
#
# Measured 2026-09-01 across the three channels: twelve days of silence with
# every pin already at its newest upstream tag. That is a live Dependabot with
# nothing to do, and a gate that reddens for it teaches people to merge over
# red. Over the limit with every pin current passes and says why; over the
# limit with a pin behind stays the failure it was.

printf '%s\n' "$(ago 11)" > "$WORK/old.resp"

fixture "$WORK/wf-current" "actions/checkout v7.0.1" "actions/cache v6.1.0"
upstream actions/checkout v7.0.0 v7.0.1
upstream actions/cache v6.0.0 v6.1.0
out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp" "$WORK/wf-current")"; rc=$?
check "over the limit with every pin at its newest tag passes" "0" "$rc"
check "and says the silence has nothing to say, with the pin count" "1" \
	"$(printf '%s' "$out" | grep -q 'every one of the 2 pinned action(s) is at its newest upstream tag' && echo 1 || echo 0)"
check "and it asked upstream about both pins" "2" "$(git_calls | tr -d ' ')"

out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp")"; rc=$?
check "over the limit with a pin behind fails" "1" "$rc"
check "and names the pin and the tag upstream has" "1" \
	"$(printf '%s' "$out" | grep -q 'actions/checkout pinned as v7.0.0, upstream has v7.0.1' && echo 1 || echo 0)"
check "and says it is not because there was nothing to bump" "1" \
	"$(printf '%s' "$out" | grep -q 'not because there was nothing to bump' && echo 1 || echo 0)"

# A newer tag that is not the exact-semver shape (a major alias, a pre-release)
# must not count as "upstream has more": the step compares exact versions only.
fixture "$WORK/wf-alias" "actions/checkout v7.0.1"
upstream actions/checkout v7.0.1 v7 v8.0.0-rc.1
rc=0; run_step "$MAX_AGE_DAYS" "$WORK/old.resp" "$WORK/wf-alias" >/dev/null || rc=$?
check "a major alias or pre-release tag upstream does not count as behind" "0" "$rc"

# "Cannot read it" is a failure, never a skip.
fixture "$WORK/wf-unreadable" "actions/checkout v7.0.1" "example/vanished v1.0.0"
upstream actions/checkout v7.0.1
out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp" "$WORK/wf-unreadable")"; rc=$?
check "an upstream that cannot be read fails rather than passing as current" "1" "$rc"
check "and names the pin it could not read" "1" \
	"$(printf '%s' "$out" | grep -q 'example/vanished pinned as v1.0.0: could not read upstream tags' && echo 1 || echo 0)"

# A pin whose comment is not an exact version cannot be compared, so it fails.
fixture "$WORK/wf-vague" "actions/checkout v7"
rc=0; out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp" "$WORK/wf-vague")" || rc=$?
check "a pin commented with a major alias fails as unreadable" "1" "$rc"
check "and says the version is not exact" "1" \
	"$(printf '%s' "$out" | grep -q 'not an exact version' && echo 1 || echo 0)"

# Within the limit nothing upstream is asked at all: the comparison is the
# tie-breaker for silence, not a second gate.
printf '%s\n' "$(ago 1)" > "$WORK/recent.resp"
rc=0; run_step "$MAX_AGE_DAYS" "$WORK/recent.resp" "$WORK/wf-unreadable" >/dev/null || rc=$?
check "within the limit passes without asking upstream, even with an unreadable pin" "0" "$rc"
check "and made no git call" "0" "$(git_calls | tr -d ' ')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
