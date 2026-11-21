#!/usr/bin/env bash
# Behaviour tests for scripts/quality/check-test-job-not-switchable.sh, the
# check reusable-workflow-lint.yml runs so that the required `shell / test`
# check cannot be switched off without failing.
#
# It is a gate over another gate. It parses every caller of reusable-shell-ci
# and refuses, each with its own message, the mechanisms that can switch the
# required check off without failing it: a job-level `if:` or `needs:`, an
# empty or malformed test-command, a literal block scalar, the suppression
# forms (`|| true`, `true ||`, `exit 0`) and the absence of any caller.
#
# Each case plants a workflow in a temporary tree shaped like a repository and
# runs the script as it ships. Every refusal asserts which refusal, and every
# refusal is paired with an acceptance of the same shape just inside the line.
#
# Requires: python3 with PyYAML.
# The fixtures below carry backticks the assertion reads, so they must reach
# the file unexpanded. Single quotes are the point, not an oversight.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/quality/check-test-job-not-switchable.sh"
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

new() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/.github/workflows"; printf '%s' "$WORK/t"; }
run_in() { # $1=dir $2=script -> stdout+stderr, status in $?
	( cd "$1" && bash "$2" 2>&1 )
}
said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

# A caller of reusable-shell-ci, with whatever test-command the case wants.
# The value is folded onto following lines by `>-`, so a YAML block scalar
# here is what every real caller uses too; the parser reads it back into a
# single string before checking it.
caller() { # $1=dir $2=test-command value (may be empty)
	cat > "$1/.github/workflows/tests.yml" <<EOF
name: Tests
on: pull_request
jobs:
  shell:
    uses: ./.github/workflows/reusable-shell-ci.yml
    with:
      test-command: >-
        $2
      apt-packages: shellcheck
EOF
}

# ===========================================================================
# A required test job must not be switchable off
# ===========================================================================

# Like caller(), but adds a job-level `if:` value. The previous text match
# could not see this key at all; the parser must, and must refuse any value
# because any conditional on a caller of a required job is a switch.
caller_if() { # $1=dir $2=test-command value $3=if value
	cat > "$1/.github/workflows/tests.yml" <<EOF
name: Tests
on: pull_request
jobs:
  shell:
    if: $3
    uses: ./.github/workflows/reusable-shell-ci.yml
    with:
      test-command: >-
        $2
      apt-packages: shellcheck
EOF
}

# --- the repository's real caller is the positive control ------------------
d="$(new)"
cp "$HERE/.github/workflows/tests.yml" "$d/.github/workflows/"
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "the real tests.yml caller stays accepted" "0" "$rc"
check "and the step says every caller passes" "1" \
	"$(said "$out" 'every reusable-shell-ci caller passes')"

# --- the runner form ------------------------------------------------------
#
# The suites can also be handed to a runner that executes each one and requires
# the sentinel it prints as its last line. A `&&` chain cannot tell a suite that
# ran every assertion from one that exited early having run three, so the
# grammar accepts that shape too, with the same rule about what may follow.
d="$(new)"; caller "$d" './tests/ci/suites/check-suite-completeness.test.sh ./tests/one.test.sh ./tests/two.test.sh'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "the runner form with suites after it passes" "0" "$rc"

# The runner with nothing to run is the empty test-command wearing a disguise:
# it exits 0 having tested nothing, and the required check reports Success.
d="$(new)"; caller "$d" './tests/ci/suites/check-suite-completeness.test.sh'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "the runner with no suites after it is refused" "1" "$rc"
check "and the message says it would test nothing" "1" \
	"$(said "$out" 'no suites to run')"

d="$(new)"; caller "$d" './tests/ci/suites/check-suite-completeness.test.sh --quiet ./tests/one.test.sh'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "an argument to the runner that is not a suite is refused" "1" "$rc"
check "and the message quotes the argument it refused" "1" \
	"$(said "$out" '`--quiet`')"

# The suppression forms are checked before the shape is decided, so they are
# refused in this form as well and for the same reason.
d="$(new)"; caller "$d" './tests/ci/suites/check-suite-completeness.test.sh ./tests/one.test.sh || true'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "the runner form with || true is still refused" "1" "$rc"
check "and it is refused as the suppression, not as the grammar" "1" \
	"$(said "$out" '`|| true` in its')"

# A literal block scalar (`|`) keeps newlines, so the runner sits on line one
# and each suite sits on its own line: three shell statements after YAML
# parses, not one. Without this check, the guard joins the lines back into a
# single string and the suite never fails the required check.
caller_lit() { # $1=dir  $2..=lines of the test-command body
	{
		echo 'name: Tests'
		echo 'on: pull_request'
		echo 'jobs:'
		echo '  shell:'
		echo '    uses: ./.github/workflows/reusable-shell-ci.yml'
		echo '    with:'
		echo '      test-command: |'
		shift
		for line in "$@"; do
			echo "        $line"
		done
		echo '      apt-packages: shellcheck'
	} > "$1/.github/workflows/tests.yml"
}

d="$(new)"
caller_lit "$d" \
	'./tests/ci/suites/check-suite-completeness.test.sh' \
	'./tests/one.test.sh' \
	'./tests/two.test.sh'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a literal block scalar in test-command is refused" "1" "$rc"
check "and the refusal says the statements would run separately" "1" \
	"$(said "$out" 'separate shell statements')"

# --- a caller that runs a suite passes (sanity check) ---------------------
d="$(new)"; caller "$d" './tests/one.test.sh && ./tests/two.test.sh'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a caller whose test-command runs a suite passes" "0" "$rc"

# --- a job-level `if:` on a caller is refused, for that reason -------------
d="$(new)"; caller_if "$d" './tests/one.test.sh' 'false'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a caller with a job-level if: is refused" "1" "$rc"
check "and the message names the if: defect, not something else" "1" \
	"$(said "$out" 'job-level `if:`')"
check "and the offending job is named" "1" "$(said "$out" '`shell`')"
check "and no grammar message fires alongside" "0" \
	"$(said "$out" 'first non-blank token')"

# --- `needs:` on a caller is refused, for that reason ----------------------
d="$(new)"; caller_if "$d" './tests/one.test.sh' 'false'
sed -i 's/^    if: false$/    needs: noop/' "$d/.github/workflows/tests.yml"
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a caller with needs: is refused" "1" "$rc"
check "and the message names the needs: defect" "1" "$(said "$out" 'carries `needs:`')"
check "and not the if: one" "0" "$(said "$out" 'job-level `if:`')"

# --- a test-command whose first token is not a suite is refused ------------
d="$(new)"; caller "$d" 'echo tests are elsewhere'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a test-command that runs no ./tests/*.test.sh is refused" "1" "$rc"
check "and the message names the first-token defect" "1" \
	"$(said "$out" 'first non-blank token is not a suite invocation')"
check "and the offending workflow is named" "1" "$(said "$out" 'tests.yml')"
check "and no if: message fires alongside" "0" \
	"$(said "$out" 'job-level `if:`')"

# --- an empty test-command is refused (existing rule, kept) ---------------
d="$(new)"; caller "$d" ''
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a caller with an empty test-command is refused" "1" "$rc"
check "and it is refused for the test-command, not something else" "1" \
	"$(said "$out" 'without a test-command that runs any suite')"
check "and the offending workflow is named" "1" "$(said "$out" 'tests.yml')"

# --- a `|| true` anywhere in the test-command is refused -------------------
d="$(new)"; caller "$d" './tests/one.test.sh || true'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a test-command with || true is refused" "1" "$rc"
check "and the message names the infix suppression form" "1" \
	"$(said "$out" '`|| true`')"
check "and it is not refused as the prefix form" "0" \
	"$(said "$out" 'starts with `true ||`')"
check "and it is not refused as the exit-0 form" "0" \
	"$(said "$out" '`exit 0`')"

# --- a `true ||` prefix on the test-command is refused --------------------
d="$(new)"; caller "$d" 'true || ./tests/one.test.sh && ./tests/two.test.sh'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a test-command with true || prefix is refused" "1" "$rc"
check "and the message names the prefix form" "1" \
	"$(said "$out" 'starts with `true ||`')"
check "and it is not refused as the infix form" "0" \
	"$(said "$out" '`|| true`')"
check "and it is not refused as the exit-0 form" "0" \
	"$(said "$out" '`exit 0`')"

# --- a leading `exit 0` on the test-command is refused --------------------
d="$(new)"; caller "$d" 'exit 0'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a test-command starting with exit 0 is refused" "1" "$rc"
check "and the message names the exit-0 form" "1" \
	"$(said "$out" '`exit 0`')"
check "and it is not refused as the prefix form" "0" \
	"$(said "$out" 'starts with `true ||`')"
check "and it is not refused as the infix form" "0" \
	"$(said "$out" '`|| true`')"

# --- no caller at all is refused, and named as the other failure ----------
d="$(new)"
cat > "$d/.github/workflows/other.yml" <<'EOF'
name: Other
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: true
EOF
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a tree with no reusable-shell-ci caller is refused" "1" "$rc"
check "and it says no workflow calls it, which is the other failure" "1" \
	"$(said "$out" 'no workflow calls reusable-shell-ci')"

# --- the reusable itself is not counted as a caller -----------------------
d="$(new)"
cp "$HERE/.github/workflows/reusable-shell-ci.yml" "$d/.github/workflows/"
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "the reusable's own file does not count as a caller" "1" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
