#!/usr/bin/env bash
#
# The `suite-needed` mode of scripts/quality/scope/ci-job-scope.sh answers, for one
# suite that has a job of its own, whether a change can alter its verdict. The
# job asks before it installs anything, so a wrong "false" lets a change merge
# without the suite that should have judged it and a wrong "true" costs a
# minute. Most cases below plant a way to slip through and require the answer
# to be true; the few that require false only mean something because those
# show the resolver can tell the two apart.
#
# It differs from the `suites` mode in two ways, and both have cases here: it
# also answers a push to main, from the commit the push replaced (named by
# BEFORE_SHA), and it takes one suite and no list.
#
# Every repository is real git: a base commit, a branch, and the merge commit
# GitHub builds for a pull request (two parents), or the single commit a push
# to main leaves behind.
#
# Requires: bash, git, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RESOLVER="$HERE/scripts/quality/scope/ci-job-scope.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

SUITE=tests/a/one.test.sh
MAP=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n\ntests/b/two.test.sh\n\tscripts/b/**\n'
RUNNER=tests/ci/suites/check-suite-completeness.test.sh

# repo <name>: a base commit with the resolver, the map, the runner and a few
# files, and the checkout on a branch ready to take the change.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/scripts/a" "$R/scripts/b" "$R/tests/a" "$R/tests/b" "$R/tests/ci/suites"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/scope/ci-job-scope.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/scope/suite-scope.txt"
	printf 'runner\n' > "$R/$RUNNER"
	printf 'x\n' > "$R/scripts/a/x.sh"; printf 'x\n' > "$R/scripts/b/y.sh"; printf 'readme\n' > "$R/README.md"
	printf 'x\n' > "$R/tests/a/one.test.sh"; printf 'x\n' > "$R/tests/b/two.test.sh"
	git -C "$R" add -A; git -C "$R" commit -qm base
	BASE="$(git -C "$R" rev-parse HEAD)"
	git -C "$R" checkout -q -b pr
}
# merge: commit the pending changes on the branch and build the merge commit.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# push: commit the pending changes straight on main, as a squash merge leaves it.
push() {
	git -C "$R" checkout -q main
	git -C "$R" add -A; git -C "$R" commit -qm change
}
# base_map <content>: change the map in the base (main), then branch again.
# "-" removes it.
base_map() {
	git -C "$R" checkout -q main
	if [ "$1" = "-" ]; then git -C "$R" rm -q scripts/quality/scope/suite-scope.txt
	else printf '%s' "$1" > "$R/scripts/quality/scope/suite-scope.txt"; fi
	git -C "$R" add -A; git -C "$R" commit -qm "base map"
	BASE="$(git -C "$R" rev-parse HEAD)"
	git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
}
# ask <event> [before] [suite...]: what the resolver prints, from the copy the
# checkout carries.
ask() {
	local event="$1" before="${2-}"
	if [ $# -ge 2 ]; then shift 2; else shift; fi
	( cd "$R" && EVENT="$event" BEFORE_SHA="$before" bash scripts/quality/scope/ci-job-scope.sh suite-needed "${@-$SUITE}" 2>/dev/null )
}
pr() { ask pull_request "" "$@"; }
# A push is asked with the commit it replaced, which is main's first parent.
pushed() { ask push "$(git -C "$R" rev-parse HEAD^1)"; }
# sabotage <file> <old> <new>: replace one piece of a file and stop loudly if it
# is not there exactly once, so a case cannot pass because the sabotage did not
# land. It is the control of the cases that follow it.
sabotage() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the sabotage target is not there exactly once: %r" % (old,))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

# --- a pull request: the suite runs only when something it reads changed -------

repo outside; echo more >> "$R/README.md"; merge
check "a change no pattern covers does not need the suite" "false" "$(pr)"
check "and the name may carry the leading ./ the workflow uses" "false" "$(pr ./$SUITE)"

repo inside; echo more >> "$R/scripts/a/x.sh"; merge
check "a change under a pattern of the entry needs the suite" "true" "$(pr)"

repo other; echo more >> "$R/scripts/b/y.sh"; merge
check "a change under another suite's pattern does not" "false" "$(pr)"

repo self; echo more >> "$R/tests/b/two.test.sh"; merge
check "a suite that changes is needed even when its entry omits its own file" "true" "$(pr tests/b/two.test.sh)"
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" 'return name in paths or affects(patterns, paths) or affects(GLOBAL_INPUTS, paths)' 'return affects(patterns, paths) or affects(GLOBAL_INPUTS, paths)'
check "control: without the clause that suite is skipped" "false" "$(pr tests/b/two.test.sh)"

for global in scripts/quality/scope/ci-job-scope.sh scripts/quality/scope/suite-scope.txt "$RUNNER"; do
	repo "global-${global##*/}"; echo more >> "$R/$global"; merge
	check "a change to $global needs the suite" "true" "$(pr)"
done

repo rename; git -C "$R" mv scripts/b/y.sh scripts/b/renamed.sh; merge
check "a rename needs the suite, whatever it renamed" "true" "$(pr)"

repo delete; git -C "$R" rm -q scripts/a/x.sh; merge
check "a deleted file counts as a change to its area" "true" "$(pr)"

repo noentry; echo more >> "$R/README.md"; merge
check "a suite the map does not know is needed" "true" "$(pr tests/c/three.test.sh)"

# --- every doubt answers true ----------------------------------------------------

repo nomap; base_map -; echo more >> "$R/README.md"; merge
check "a base without the map needs the suite" "true" "$(pr)"

repo nopattern; base_map $'tests/a/one.test.sh\n'; echo more >> "$R/README.md"; merge
check "an entry with no pattern needs the suite" "true" "$(pr)"

repo twice; base_map $'tests/a/one.test.sh\n\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/README.md"; merge
check "a suite listed twice needs the suite" "true" "$(pr)"

repo ff; echo more >> "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm change
check "a checkout that is not the merge commit needs the suite" "true" "$(pr)"

repo empty; git -C "$R" commit -q --allow-empty -m empty; git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
check "an empty diff needs the suite" "true" "$(pr)"

repo narrow; echo more >> "$R/scripts/a/x.sh"
printf 'tests/a/one.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"; merge
check "a pull request that narrows its own entry is judged by the base's map" "true" "$(pr)"

repo event; echo more >> "$R/README.md"; merge
check "a schedule needs the suite" "true" "$(ask schedule)"
check "a manual dispatch needs the suite" "true" "$(ask workflow_dispatch)"
check "an unknown event needs the suite" "true" "$(ask "")"

repo arity; echo more >> "$R/README.md"; merge
check "two suites in one question are refused with the fail-open answer" "true" "$(pr "$SUITE" tests/b/two.test.sh)"
check "no suite is refused with the fail-open answer" "true" "$( cd "$R" && EVENT=pull_request bash scripts/quality/scope/ci-job-scope.sh suite-needed 2>/dev/null )"

repo broken; echo more >> "$R/README.md"; merge
check "outside a git repository the answer is the fail-open one" "true" \
	"$( cd "$WORK" && EVENT=pull_request bash "$R/scripts/quality/scope/ci-job-scope.sh" suite-needed "$SUITE" 2>/dev/null )"

# --- a push to main: the same answer, from the commit the push replaced ---------

repo push-out; echo more >> "$R/README.md"; push
check "a push that changes nothing the suite reads does not need it" "false" "$(pushed)"

repo push-in; echo more >> "$R/scripts/a/x.sh"; push
check "a push that changes something it reads needs it" "true" "$(pushed)"

repo push-global; echo more >> "$R/scripts/quality/scope/suite-scope.txt"; push
check "a push that changes the map needs it" "true" "$(pushed)"

repo push-rename; git -C "$R" mv scripts/b/y.sh scripts/b/renamed.sh; push
check "a push that renames a file needs it" "true" "$(pushed)"

repo push-two; echo more >> "$R/scripts/a/x.sh"; push
echo more >> "$R/README.md"; push
check "a push of two commits is one change nobody can read, and needs it" "true" \
	"$(ask push "$BASE")"
check "control: the last commit alone is outside the patterns" "false" "$(pushed)"

repo push-wrong; echo more >> "$R/README.md"; push
check "a before that is not the parent needs the suite" "true" "$(ask push "$(printf '%040d' 7)")"
check "an all-zero before (a new branch) needs the suite" "true" "$(ask push "$(printf '%040d' 0)")"
check "an empty before needs the suite" "true" "$(ask push "")"
check "a before that is not a commit name needs the suite" "true" "$(ask push 'HEAD^1')"
check "a before in capitals needs the suite" "true" "$(ask push "$(git -C "$R" rev-parse HEAD^1 | tr 'a-f' 'A-F')")"

repo push-merge; echo more >> "$R/README.md"; merge
check "a push whose commit is a merge reads the diff against its first parent" "false" "$(pushed)"

repo push-nomap; base_map -; git -C "$R" checkout -q main; echo more >> "$R/README.md"; push
check "a push whose parent has no map needs the suite" "true" "$(pushed)"

repo push-narrow; echo more >> "$R/scripts/a/x.sh"
printf 'tests/a/one.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"; push
check "a push is judged by the map of the commit it replaced" "true" "$(pushed)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
