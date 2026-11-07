#!/usr/bin/env bash
#
# The `suites` mode of scripts/quality/ci-job-scope.sh decides which suites a
# pull request can affect. A wrong skip lets a change merge untested, so most of
# the cases here plant a way to slip through and require every suite to run, and
# the few that require a skip only mean something because those prove the
# resolver can tell. Every repository below is real git: a base commit, a
# branch, and the merge commit GitHub would build (HEAD with two parents).
#
# Requires: bash, git, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$HERE/scripts/quality/ci-job-scope.sh"
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

SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"
MAP=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n\ntests/b/two.test.sh\n\tscripts/b/**\n\tREADME.md\n\ttests/b/two.test.sh\n'
# Note: tests/c/three.test.sh has no entry, so it must always run.

# repo <name>: a base commit with the map and the resolver, and the checkout on
# a branch ready to take the pull request's changes.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality" "$R/scripts/a" "$R/scripts/b" "$R/tests/a" "$R/tests/b" "$R/tests/c" "$R/tests/ci/suites"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/ci-job-scope.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/suite-scope.txt"
	printf 'runner\n' > "$R/tests/ci/suites/check-suite-completeness.test.sh"
	printf 'x\n' > "$R/scripts/a/x.sh"; printf 'x\n' > "$R/scripts/b/y.sh"; printf 'readme\n' > "$R/README.md"
	printf 'docs\n' > "$R/DOCS.md"; printf 'x\n' > "$R/tests/a/one.test.sh"; printf 'x\n' > "$R/tests/b/two.test.sh"; printf 'x\n' > "$R/tests/c/three.test.sh"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# base_map <content>: change the map in the BASE (main), not in the pull
# request, and branch the pull request from there. "-" removes the map.
base_map() {
	git -C "$R" checkout -q main
	if [ "$1" = "-" ]; then git -C "$R" rm -q scripts/quality/suite-scope.txt
	else printf '%s' "$1" > "$R/scripts/quality/suite-scope.txt"; fi
	git -C "$R" add -A; git -C "$R" commit -qm "base map"
	git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
}
# merge: commit the pending changes on the branch and build the merge commit.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# decide: the suites kept out of $SUITES, space-separated, in the order given.
# $SUITES is a list of plain words, so it is expanded unquoted on purpose.
decide() {
	# shellcheck disable=SC2086
	( cd "$R" && bash scripts/quality/ci-job-scope.sh suites $SUITES 2>/dev/null | tr '\n' ' ' | sed 's/ $//' )
}
ALL="$SUITES"

# A suite whose entry does not list its own file still runs when only that file
# changes (issue #370). The control is the resolver without the condition.
SELF_MAP=$'tests/d/four.test.sh\n\tscripts/d/**\n'
repo self
git -C "$R" checkout -q main; mkdir -p "$R/tests/d"; printf 'x\n' > "$R/tests/d/four.test.sh"
git -C "$R" add -A; git -C "$R" commit -qm "the suite"
base_map "$SELF_MAP"
echo more >> "$R/tests/d/four.test.sh"; merge
SUITES="tests/d/four.test.sh"
check "a suite whose entry omits its own file still runs when only it changes" \
	"tests/d/four.test.sh" "$(decide)"
sed 's/if candidate in paths or affects/if affects/' "$RESOLVER" > "$WORK/resolver-cut.sh"
check "the sabotage changed the resolver" "1" "$(cmp -s "$RESOLVER" "$WORK/resolver-cut.sh" && echo 0 || echo 1)"
cp "$WORK/resolver-cut.sh" "$R/scripts/quality/ci-job-scope.sh"
check "without the condition that suite is skipped (the run is the condition's)" \
	"" "$(decide)"
SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"

repo docs; echo more >> "$R/DOCS.md"; merge
check "a change no entry covers skips every mapped suite, and the unmapped one still runs" \
	"tests/c/three.test.sh" "$(decide)"

repo area; echo more >> "$R/scripts/a/x.sh"; merge
check "a change under one area runs that area's suite and the unmapped one" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

repo exact; echo more >> "$R/README.md"; merge
check "an exact file entry matches that file" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"

repo dots; echo more >> "$R/scripts/ax.sh"; mkdir -p "$R/scripts/ab"; echo y > "$R/scripts/ab/z.sh"; merge
check "a sibling directory whose name only starts like the area does not match it" \
	"tests/c/three.test.sh" "$(decide)"

repo space; mkdir -p "$R/scripts/a/sub dir"; echo y > "$R/scripts/a/sub dir/a b.sh"; merge
check "a path with spaces under ** is matched" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

repo spelling; echo more >> "$R/scripts/a/x.sh"; merge
check "the workflow's ./ spelling is normalised" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$( ( cd "$R" && bash scripts/quality/ci-job-scope.sh suites ./tests/a/one.test.sh ./tests/b/two.test.sh ./tests/c/three.test.sh | tr '\n' ' ' | sed 's/ $//' ) )"

# --- the things a pull request must not be able to do to its own scope ---------

repo map; printf 'tests/a/one.test.sh\n\tnothing/**\n' > "$R/scripts/quality/suite-scope.txt"; merge
check "a pull request that rewrites the map runs every suite" "$ALL" "$(decide)"

repo resolver; echo '# edited' >> "$R/scripts/quality/ci-job-scope.sh"; merge
check "a pull request that edits the resolver runs every suite" "$ALL" "$(decide)"

repo runner; echo more >> "$R/tests/ci/suites/check-suite-completeness.test.sh"; merge
check "a pull request that edits the runner runs every suite" "$ALL" "$(decide)"

# --- the decision fails open -----------------------------------------------------

repo rename; git -C "$R" mv scripts/b/y.sh scripts/b/renamed.sh; merge
check "a rename runs every suite" "$ALL" "$(decide)"

repo delete; git -C "$R" rm -q scripts/b/y.sh; merge
check "a deleted file counts as a change to its area" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"
# (scripts/b/** is in the entry of tests/b/two.test.sh)

repo ff; echo more >> "$R/scripts/a/x.sh"; git -C "$R" add -A; git -C "$R" commit -qm change
check "a checkout that is not the merge commit runs every suite" "$ALL" "$(decide)"

repo empty; git -C "$R" commit -q --allow-empty -m empty; git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
check "an empty diff runs every suite" "$ALL" "$(decide)"

repo nomap; base_map -; echo more >> "$R/DOCS.md"; merge
check "a base commit without the map runs every suite" "$ALL" "$(decide)"

repo badmap; base_map $'tests/a/one.test.sh\n'; echo more >> "$R/DOCS.md"; merge
check "a map entry with no pattern runs every suite" "$ALL" "$(decide)"

repo dup; base_map $'tests/a/one.test.sh\n\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a suite listed twice in the map runs every suite" "$ALL" "$(decide)"

repo orphan; base_map $'\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a pattern before any suite runs every suite" "$ALL" "$(decide)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
