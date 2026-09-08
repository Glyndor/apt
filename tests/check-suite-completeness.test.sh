#!/usr/bin/env bash
#
# Run every test file the workflow invokes and require each one to print its
# sentinel. The sentinel is the last line every test file writes:
#
#     printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
#
# It sits between the count line and `[ "$fail" -eq 0 ]`, so it is reached
# only after the last `check` runs. A test that exits early -- because
# someone planted `exit 0`, because `set -e` killed it on an unexpected
# error, or because anything else cut the run short -- never produces the
# sentinel, and this file names it.
#
# Why this shape, not the alternatives:
#
#   * a sidecar file. Every test would have to know the sidecar path and
#     append to it; that is plumbing into every file for one check's sake,
#     and a non-writable sidecar is a new failure mode unrelated to what
#     this catches.
#
#   * a post-hoc re-run. The chain in tests.yml runs the tests once, and
#     this file re-runs them to inspect their output. Tests that take a
#     minute to run would take two; the doubling is the cheapest cost, but
#     the property -- the test that just passed is the one whose sentinel
#     we are about to check -- is no longer true.
#
#   * parsing tests.yml inside this file. The list of files is right
#     there in the workflow, but a runner that parses YAML to find its own
#     input couples itself to the workflow's shape. The workflow lists
#     the tests as this file's arguments; that is the one place the list
#     needs to live, and tests/ci-runs-every-test.test.sh already keeps
#     it honest.
#
# Usage: check-suite-completeness.test.sh <test-file> [<test-file> ...]

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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

if [ "$#" -eq 0 ]; then
	echo "usage: $0 <test-file> [<test-file> ...]" >&2
	exit 2
fi

self="${BASH_SOURCE[0]##*/}"

# --- this runner's own case -------------------------------------------------
#
# The sentinel used to be validated against a pattern that accepted ANY
# basename, so the runner asked "did some file print a DONE line" when the
# question it exists to answer is "did THIS file reach its end". A test that
# printed a sibling's sentinel satisfied it.
#
# The case lives inside the runner rather than in a file beside it because the
# runner is the thing under test and it takes its subjects as arguments: a
# sibling test would have to invoke this file anyway. It re-runs a copy of
# itself against two fixtures, one honest and one that prints the other's
# sentinel, and requires the rejection to NAME both names. Asserting only a
# non-zero exit would be satisfied by a runner that refused for any reason at
# all, including a fixture that failed to execute.
#
# The environment variable is what stops the copy from recursing. It is set
# only on the nested invocation, never in CI.
if [ "${CHECK_SUITE_COMPLETENESS_SKIP_FIXTURE_TEST:-0}" != 1 ]; then
	WORK="$(mktemp -d)"
	trap 'rm -f "$WORK/inner.test.sh" "$WORK/outer.test.sh" "$WORK/runner.test.sh"; rmdir "$WORK" 2>/dev/null || true' EXIT

	cat > "$WORK/inner.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf 'DONE %s 0 0\n' "${BASH_SOURCE[0]##*/}"
FIXTURE

	cat > "$WORK/outer.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf 'DONE inner.test.sh 0 0\n'
FIXTURE
	chmod +x "$WORK/inner.test.sh" "$WORK/outer.test.sh"
	cp "${BASH_SOURCE[0]}" "$WORK/runner.test.sh"
	chmod +x "$WORK/runner.test.sh"

	fixture_output="$(CHECK_SUITE_COMPLETENESS_SKIP_FIXTURE_TEST=1 "$WORK/runner.test.sh" "$WORK/inner.test.sh" "$WORK/outer.test.sh" 2>&1)"
	fixture_rc=$?
	fixture_mismatch_named=0
	if [ "$fixture_rc" -ne 0 ] \
		&& printf '%s' "$fixture_output" | grep -qF -- "expected sentinel basename: outer.test.sh" \
		&& printf '%s' "$fixture_output" | grep -qF -- "arrived sentinel basename: inner.test.sh"; then
		fixture_mismatch_named=1
	fi
	check "a mismatched sentinel is rejected and names both names" "1" "$fixture_mismatch_named"
fi

# Every test file must end with a sentinel of the form
# `DONE <basename> <pass-count> <fail-count>`. The basename is what the file
# itself sees in $0 / BASH_SOURCE, so the check is by basename rather than
# the path the runner was given: a file invoked as `./tests/foo.test.sh`
# and as `tests/foo.test.sh` both report `foo.test.sh` in their sentinel,
# and either way the runner reaches the same answer.
#
# Compared field by field rather than with a regex built from the basename: a
# basename carries dots, and `foo.test.sh` as a pattern would also accept
# `fooXtestYsh`.

for f in "$@"; do
	basename="${f##*/}"
	# Skip self if invoked recursively (it would not terminate).
	[ "$basename" = "$self" ] && continue

	output="$("$f" 2>&1)"
	rc=$?

	# The test's own output is the diagnosis: the FAIL line it printed
	# when one of its checks failed, or the `ok` line that was its last
	# printed word before a planted `exit 0`. Print it so the operator
	# who comes after the runner has the same picture.
	printf '%s\n' "$output"

	# The sentinel, if the test reached it, is the last line of output.
	# Command substitution strips trailing newlines, so the sentinel's
	# terminating \n is not in $output; the last line is the sentinel's
	# body.
	last_line="$(printf '%s' "$output" | tail -n 1)"
	arrived_name="<none>"
	has_sentinel=0
	if [ -n "$last_line" ]; then
		read -r -a fields <<< "$last_line"
		if [ "${#fields[@]}" -eq 4 ] \
			&& [ "${fields[0]}" = "DONE" ] \
			&& [ "${fields[1]}" = "$basename" ] \
			&& [[ "${fields[2]}" =~ ^[0-9]+$ ]] \
			&& [[ "${fields[3]}" =~ ^[0-9]+$ ]]; then
			has_sentinel=1
			arrived_name="${fields[1]}"
		elif [ "${#fields[@]}" -ge 2 ]; then
			arrived_name="${fields[1]}"
		fi
	fi

	check "$basename reached its end" "1" "$has_sentinel"
	if [ "$has_sentinel" -eq 0 ]; then
		echo "        expected sentinel basename: $basename"
		echo "        arrived sentinel basename: $arrived_name"
		echo "        last line was: $last_line"
	fi

	if [ "$rc" -ne 0 ]; then
		check "$basename exited 0" "1" "0"
	else
		check "$basename exited 0" "1" "1"
	fi
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "$self" "$pass" "$fail"
[ "$fail" -eq 0 ]
