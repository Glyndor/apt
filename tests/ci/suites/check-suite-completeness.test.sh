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
#     needs to live, and tests/ci/suites/ci-runs-every-test.test.sh already keeps
#     it honest.
#
# Usage: check-suite-completeness.test.sh <test-file> [<test-file> ...]

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1

pass=0
fail=0
skipped=0

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

# --- which suites this change can affect -------------------------------------
#
# The job runs every suite on every pull request, and the three slowest of
# them are integration suites whose verdict does not depend on the change:
# measured on 2026-11-06, tests/verify/verify-published.test.sh,
# tests/publish/purge-cache-budget.test.sh and
# tests/publication/health-check/health-check-workflow.test.sh are 46 % of the 151 s the whole
# suite takes on this repository.
#
# scripts/quality/ci-job-scope.sh, in its `suites` mode, says which suites
# this change can affect, using the map in scripts/quality/suite-scope.txt.
# The decision is taken with the resolver and the map as they are in the BASE
# commit, never as this pull request ships them, so a pull request that
# narrows the map to hide its own suite gets the full set instead. That is the
# rule the shellcheck job of the same reusable already follows for the same
# script, and the rule the CI standard states: a gate script is read from the
# base commit, never from the checkout of the pull request it is judging.
#
# Everything here fails open. A push, a schedule, an unreadable diff, a
# rename, a resolver that cannot be read from the base commit, a runner that
# is not the base copy, a decision that names a suite this job was not given:
# all of them run every suite. A wrong skip lets a change merge untested; a
# wrong run costs seconds.
#
# The job and its required check `shell / test` report exactly as before.
# Only the decision to EXECUTE a suite changes, and the workflow still names
# every suite, so tests/ci/suites/ci-runs-every-test.test.sh still sees a
# complete list.
#
# The suite names the workflow uses carry a leading `./`; the map does not.
# Both are normalised to the same spelling here.

declare -A candidates=()
for f in "$@"; do
	name="$f"
	case "$name" in
		./*) name="${name#./}" ;;
	esac
	candidates["$name"]=1
done

declare -A selected=()
scoped=0

if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] \
	&& [ "${CHECK_SUITE_COMPLETENESS_SKIP_FIXTURE_TEST:-0}" != 1 ] \
	&& [ "$#" -gt 0 ]; then
	# The runner is the one piece of this mechanism a pull request can
	# rewrite. The resolver and the map are read from the BASE commit, so a
	# pull request that narrows them gets the full set; the runner is the
	# file that is running, and nothing else decides what it does with the
	# decision. So it does not get to narrow anything on a pull request that
	# touched it: compare it with the base copy and refuse to scope when the
	# two differ. A pull request that rewrites the file from scratch can
	# still delete this comparison -- no check inside the job can stop that,
	# because the thing that would stop it is the thing being rewritten.
	# What this closes is the pull request that EDITS the runner, which is
	# the one a reviewer reads.
	self_rel="tests/ci/suites/check-suite-completeness.test.sh"
	base_self="$(mktemp "${TMPDIR:-/tmp}/suite-scope-self.XXXXXX" 2>/dev/null)" || base_self=""
	self_is_base=0
	if [ -n "$base_self" ] && git show "HEAD^1:$self_rel" > "$base_self" 2>/dev/null; then
		cmp -s "$self_rel" "$base_self" && self_is_base=1
	fi
	[ -n "$base_self" ] && rm -f "$base_self"

	resolver="$(mktemp "${TMPDIR:-/tmp}/suite-scope.XXXXXX" 2>/dev/null)" || resolver=""
	decision=""
	if [ -n "$resolver" ] \
		&& git show HEAD^1:scripts/quality/ci-job-scope.sh > "$resolver" 2>/dev/null; then
		decision="$(bash "$resolver" suites "$@" 2>/dev/null)" || decision=""
	fi
	[ -n "$resolver" ] && rm -f "$resolver"

	# A decision is only a decision when every name in it is a suite this job
	# was given. Anything else means the scope could not be established, and
	# an established scope is the only thing that may skip a suite.
	usable=1
	[ -n "$decision" ] || usable=0
	[ "$self_is_base" = 1 ] || usable=0
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		case "$name" in
			./*) name="${name#./}" ;;
		esac
		[ -n "${candidates[$name]:-}" ] || usable=0
	done <<< "$decision"

	if [ "$usable" = 1 ]; then
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			case "$name" in
				./*) name="${name#./}" ;;
			esac
			selected["$name"]=1
		done <<< "$decision"
		scoped=1
	fi
fi

if [ "$scoped" = 1 ]; then
	echo "scope: $(( ${#selected[@]} )) of $# suites can be affected by this change; the rest cannot."
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "### Suite scope"
			echo
			echo "$(( ${#selected[@]} )) of $# suites can be affected by this change."
			echo "The other $(( $# - ${#selected[@]} )) were not run."
		} >> "$GITHUB_STEP_SUMMARY"
	fi
fi

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

	name="$f"
	case "$name" in
		./*) name="${name#./}" ;;
	esac
	# A suite this change cannot affect is not run. It is not a failure and
	# not a pass: it is a question this change cannot change the answer to.
	if [ "$scoped" = 1 ] && [ -z "${selected[$name]:-}" ]; then
		printf 'skip  %s (this change cannot alter its verdict)\n' "$basename"
		skipped=$((skipped + 1))
		continue
	fi

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
if [ "$skipped" -gt 0 ]; then
	echo "$skipped suite(s) were not run: this change cannot alter their verdict."
fi
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "$self" "$pass" "$fail"
[ "$fail" -eq 0 ]
