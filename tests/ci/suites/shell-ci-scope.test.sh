#!/usr/bin/env bash
#
# The test suite is skipped only for a pull request that touches nothing but
# paths the caller listed in `skip-suite-paths`. A wrong "skip" lets a change
# merge untested, so the decision is run here against real merge commits, taken
# from the shipped workflow rather than a copy of it:
#
#   * only listed paths                                   -> skip
#   * an empty list                                       -> run (opt-in)
#   * a listed path with any other                        -> run
#   * a script renamed into a listed directory            -> run (both paths count)
#   * a push, a schedule, an unreadable diff              -> run
#
# And the list this repository passes must not contain a file the suite reads:
# README.md is a test input in every channel repository, so a list that grows to
# include it would let a change that breaks a test merge unseen.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/reusable-shell-ci.yml"
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

python3 - "$WORKFLOW" > "$WORK/scope.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for step in wf["jobs"]["test"]["steps"]:
    if step.get("id") == "scope":
        print(step["run"])
        break
else:
    sys.exit("no step with id scope in the test job")
PY
if [ ! -s "$WORK/scope.sh" ]; then
	echo "FAIL  could not extract the scope step from $WORKFLOW" >&2
	exit 1
fi

# A repository with one base commit, then a pull-request branch merged with a
# merge commit, as the checkout of refs/pull/N/merge would be.
# $1 = name  $2 = shell snippet that changes the tree on the branch
scenario() {
	local d="$WORK/$1"
	mkdir -p "$d"
	(
		cd "$d" || exit 1
		git init -q -b main
		git config user.name t
		git config user.email t@example.invalid
		mkdir -p scripts docs tests
		echo '#!/bin/sh' > scripts/run.sh
		echo readme > README.md
		echo doc > docs/a.md
		git add -A
		git commit -q -m base
		git checkout -q -b pr
		eval "$2"
		git add -A
		git commit -q -m change || true
		git checkout -q main
		git merge -q --no-ff pr -m merge
	)
}

LIST="CONTRIBUTING.md docs/*.md"

# $1 = scenario dir, $2 = event name, $3 = skip list (default $LIST)
# -> prints docs_only value
decide() {
	local out="$WORK/out-$1-$2"
	: > "$out"
	(
		cd "$WORK/$1" || exit 1
		EVENT="$2" SKIP_PATHS="${3-$LIST}" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY=/dev/null \
			bash "$WORK/scope.sh" >/dev/null 2>&1
	)
	sed -n 's/^docs_only=//p' "$out"
}

scenario listed 'echo more >> docs/a.md; echo x > CONTRIBUTING.md; mkdir -p docs/sub; echo y > docs/sub/b.md'
check "only listed paths on a pull request skips the suite" "true" "$(decide listed pull_request)"
check "the same change on a push runs it" "false" "$(decide listed push)"
check "and on a schedule" "false" "$(decide listed schedule)"
check "with an empty list nothing is ever skipped" "false" "$(decide listed pull_request '')"
check "with a blank list nothing is ever skipped" "false" "$(decide listed pull_request '   ')"

scenario readme 'echo more >> README.md'
check "README.md is not skipped unless the caller lists it" "false" "$(decide readme pull_request)"
check "and is skipped when the caller does list it" "true" "$(decide readme pull_request 'README.md')"

scenario code 'echo more >> docs/a.md; echo "# c" >> scripts/run.sh'
check "a listed file plus a script runs the suite" "false" "$(decide code pull_request)"

scenario testchange 'echo "# c" > tests/x.test.sh'
check "a test file alone runs the suite" "false" "$(decide testchange pull_request)"

scenario workflow 'mkdir -p .github/workflows; echo "name: x" > .github/workflows/w.yml'
check "a workflow alone runs the suite" "false" "$(decide workflow pull_request)"

scenario config 'echo "root = true" > .editorconfig'
check "a dotfile config alone runs the suite" "false" "$(decide config pull_request)"

scenario nonmd 'echo x > docs/diagram.png'
check "a non-markdown file under docs/ runs the suite" "false" "$(decide nonmd pull_request)"

scenario rename 'git mv scripts/run.sh docs/run.md'
check "a script renamed into docs/ runs the suite" "false" "$(decide rename pull_request)"

scenario deletion 'git rm -q scripts/run.sh'
check "deleting a script runs the suite" "false" "$(decide deletion pull_request)"

# The merge commit has no parent diff when nothing changed.
scenario empty 'git commit -q --allow-empty -m noop'
check "an empty change runs the suite" "false" "$(decide empty pull_request)"

mkdir -p "$WORK/shallow" && (cd "$WORK/shallow" && git init -q -b main && git config user.name t && git config user.email t@example.invalid && echo a > README.md && git add -A && git commit -q -m only)
check "a single commit, so no HEAD^1, runs the suite" "false" "$(decide shallow pull_request)"

# The list this repository really passes. Each entry's literal prefix must not
# appear in anything the suite reads or runs, other than this test and the
# workflow files themselves.
caller_list="$(python3 - "$HERE/.github/workflows/tests.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    print(" ".join(str(job.get("with", {}).get("skip-suite-paths", "")).split()))
PY
)"

for pattern in $caller_list; do
	prefix="${pattern%%[*?[]*}"
	hits="$(grep -rlF -- "$prefix" "$HERE/tests" "$HERE/scripts" 2>/dev/null \
		| grep -v -e 'shell-ci-scope.test.sh' | tr '\n' ' ')"
	check "the suite does not read ${pattern} (found in: ${hits:-nowhere})" "" "$hits"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
