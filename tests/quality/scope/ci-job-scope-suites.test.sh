#!/usr/bin/env bash
#
# The `suites` mode of scripts/quality/scope/ci-job-scope.sh decides which suites a
# pull request can affect. A wrong skip lets a change merge untested, so most of
# the cases here plant a way to slip through and require every suite to run, and
# the few that require a skip only mean something because those prove the
# resolver can tell. Every repository below is real git: a base commit, a
# branch, and the merge commit GitHub would build (HEAD with two parents).
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

SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"
MAP=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n\ntests/b/two.test.sh\n\tscripts/b/**\n\tREADME.md\n\ttests/b/two.test.sh\n'
# Note: tests/c/three.test.sh has no entry, so it must always run.

# repo <name>: a base commit with the map and the resolver, and the checkout on
# a branch ready to take the pull request's changes.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/scripts/a" "$R/scripts/b" "$R/tests/a" "$R/tests/b" "$R/tests/c" "$R/tests/ci/suites"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/scope/ci-job-scope.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/scope/suite-scope.txt"
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
	if [ "$1" = "-" ]; then git -C "$R" rm -q scripts/quality/scope/suite-scope.txt
	else printf '%s' "$1" > "$R/scripts/quality/scope/suite-scope.txt"; fi
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
	( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites $SUITES 2>/dev/null | tr '\n' ' ' | sed 's/ $//' )
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
cp "$WORK/resolver-cut.sh" "$R/scripts/quality/scope/ci-job-scope.sh"
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
	"tests/a/one.test.sh tests/c/three.test.sh" "$( ( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites ./tests/a/one.test.sh ./tests/b/two.test.sh ./tests/c/three.test.sh | tr '\n' ' ' | sed 's/ $//' ) )"

# --- the things a pull request must not be able to do to its own scope ---------

repo map; printf 'tests/a/one.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"; merge
check "a pull request that rewrites the map runs every suite" "$ALL" "$(decide)"

repo resolver; echo '# edited' >> "$R/scripts/quality/scope/ci-job-scope.sh"; merge
check "a pull request that edits the resolver runs every suite" "$ALL" "$(decide)"

repo runner; echo more >> "$R/tests/ci/suites/check-suite-completeness.test.sh"; merge
check "a pull request that edits the runner runs every suite" "$ALL" "$(decide)"

repo workflow; mkdir -p "$R/.github/workflows"; echo 'name: x' > "$R/.github/workflows/called.yml"; merge
check "a pull request that adds a workflow runs every suite" "$ALL" "$(decide)"
repo action; mkdir -p "$R/.github/actions/setup"; echo 'name: x' > "$R/.github/actions/setup/action.yml"; merge
check "a pull request that adds an action runs every suite" "$ALL" "$(decide)"

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

# The pull request that moves the map into its folder: the base carries it at
# the path it had before, so the map is not where the resolver looks in the
# base. Reading the pull request's own copy there would let it choose its scope,
# and the one it brings says every suite can be skipped. Its text shares nothing
# with the old one, so git sees a deletion and an addition and not a rename,
# which would run everything for a different reason.
repo moved
git -C "$R" checkout -q main
git -C "$R" mv scripts/quality/scope/suite-scope.txt scripts/quality/suite-scope.txt
git -C "$R" commit -qm "the map before it moved"
git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
git -C "$R" rm -q scripts/quality/suite-scope.txt
printf 'tests/a/one.test.sh\n\tnothing/**\ntests/b/two.test.sh\n\tnothing/**\ntests/c/three.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"
echo more >> "$R/DOCS.md"; merge
check "a base that holds the map at the path it had before the move runs every suite" "$ALL" "$(decide)"

repo badmap; base_map $'tests/a/one.test.sh\n'; echo more >> "$R/DOCS.md"; merge
check "a map entry with no pattern runs every suite" "$ALL" "$(decide)"

repo dup; base_map $'tests/a/one.test.sh\n\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a suite listed twice in the map runs every suite" "$ALL" "$(decide)"

repo orphan; base_map $'\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a pattern before any suite runs every suite" "$ALL" "$(decide)"

# --- the map in a folder: the file, and the `.txt` files of suite-scope.d read after it ------------------------

# base_dir <file name> <content>: add a file of the folder to the BASE, and branch the pull request from there.
base_dir() {
	git -C "$R" checkout -q main; mkdir -p "$R/scripts/quality/scope/suite-scope.d/$(dirname "$1")"
	printf '%s' "$2" > "$R/scripts/quality/scope/suite-scope.d/$1"
	git -C "$R" add -A; git -C "$R" commit -qm "base folder"; git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
}
ONE_ONLY=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n'
TWO_ONLY=$'tests/b/two.test.sh\n\tscripts/b/**\n\tREADME.md\n\ttests/b/two.test.sh\n'

repo dirsplit; base_map "$ONE_ONLY"; base_dir zone-b.txt "$TWO_ONLY"; echo more >> "$R/scripts/b/y.sh"; merge
check "a suite listed in a file of the folder is scoped by it: a change to its area runs it and the suite with no entry" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"
repo dirsplit2; base_map "$ONE_ONLY"; base_dir zone-b.txt "$TWO_ONLY"; echo more >> "$R/scripts/a/x.sh"; merge
check "and a change to the area of the suite in the map file does not run the one of the folder" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"
repo dirsplit3; base_map "$ONE_ONLY"; base_dir zone-b.txt "$TWO_ONLY"; echo more >> "$R/DOCS.md"; merge
check "and a change that is in no area runs only the suite with no entry" "tests/c/three.test.sh" "$(decide)"

repo dirdup; base_map "$MAP"; base_dir zone-b.txt "$TWO_ONLY"; echo more >> "$R/DOCS.md"; merge
check "a suite listed in the map file and in a file of the folder is an unusable map: every suite runs" "$ALL" "$(decide)"
repo dirdup2; base_map "$ONE_ONLY"; base_dir zone-b.txt "$TWO_ONLY"; base_dir zone-c.txt "$TWO_ONLY"; echo more >> "$R/DOCS.md"; merge
check "and so is one listed in two files of the folder" "$ALL" "$(decide)"

repo dirmd; base_map "$ONE_ONLY"; base_dir zone-b.md "$TWO_ONLY"; echo more >> "$R/scripts/a/x.sh"; merge
check "a file of the folder that is not .txt is not read, so its suite has no entry and runs" "$ALL" "$(decide)"
repo dirsub; base_map "$ONE_ONLY"; base_dir sub/zone-b.txt "$TWO_ONLY"; echo more >> "$R/scripts/a/x.sh"; merge
check "a file in a folder under it is not read either" "$ALL" "$(decide)"

repo dirempty; base_map "$ONE_ONLY"; base_dir zone-b.txt $'tests/b/two.test.sh\n'; echo more >> "$R/DOCS.md"; merge
check "an entry with no pattern in a file of the folder is an unusable map: every suite runs" "$ALL" "$(decide)"
repo dirnomap; base_map -; base_dir zone-b.txt "$TWO_ONLY"; echo more >> "$R/DOCS.md"; merge
check "a folder without the map file is no map: every suite runs" "$ALL" "$(decide)"

repo diradd; base_map "$ONE_ONLY"; base_dir zone-b.txt "$TWO_ONLY"; printf 'tests/c/three.test.sh\n\tscripts/c/**\n' > "$R/scripts/quality/scope/suite-scope.d/zone-c.txt"; merge
check "a pull request that adds a file to the folder runs every suite" "$ALL" "$(decide)"
repo dirnarrow; base_map "$ONE_ONLY"; base_dir zone-b.txt "$TWO_ONLY"; printf 'tests/b/two.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.d/zone-b.txt"; merge
check "and one that narrows a file of the folder runs every suite" "$ALL" "$(decide)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
