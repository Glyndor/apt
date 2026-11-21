#!/usr/bin/env bash
#
# The `packages` mode of scripts/quality/scope/ci-job-scope.sh narrows the list of
# APT packages a test job installs to what the suites it will run need. Every
# doubt has to answer with the whole list, and the resolver says so by exiting
# non-zero with a reason, which is what the install step reads. A guard that
# disappears does not always change that outcome: some mutants crash with a
# traceback instead, the step reads the crash as the same doubt, and the answer
# looks identical. So each case below asserts WHICH reason the resolver gave.
#
# Every repository is real git, as the install step finds it on a pull request:
# a base commit, a branch, and the merge commit GitHub builds (two parents) whose
# first parent is the base. The defect of a case is planted in the base, where
# the resolver reads its map, its dependency policy and its classifier, and the
# change itself is an ordinary one that selects a suite. A case that stops
# being a merge, or whose change selects nothing, would answer "no usable PR
# diff" before it reached the guard it names, so the cases that plant a defect
# also assert the fixture: the same repository with no defect is accepted.
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

RUNNER=tests/ci/suites/check-suite-completeness.test.sh
EDITOR=tests/quality/hygiene/check-editorconfig.test.sh
BUILD=tests/build/build-repo.test.sh
OTHER=tests/quality/lint/check-action-pins.test.sh
COMMAND="./$RUNNER ./$EDITOR ./$BUILD ./$OTHER"
PACKAGES='python3-cryptography reprepro shellcheck python3-yaml'
SCOPE=scripts/quality/scope/suite-scope.txt
DEPS=scripts/quality/scope/suite-dependencies.txt
FRAGMENT='Cannot establish dependencies; install all: '

# repo <name> [snippet]: a base commit carrying the resolver, the two maps and
# the runner, with the snippet applied first, and the checkout on a branch.
# The editor suite reads everything and needs nothing; the build suite reads
# archive.txt and needs reprepro; the other one reads other.txt.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/tests/ci/suites"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid
	git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/scope/"
	printf '%s\n\t**\n%s\n\tarchive.txt\n%s\n\tother.txt\n' "$EDITOR" "$BUILD" "$OTHER" > "$R/$SCOPE"
	printf '%s -\n%s reprepro\n%s shellcheck\n' "$EDITOR" "$BUILD" "$OTHER" > "$R/$DEPS"
	printf 'runner\n' > "$R/$RUNNER"
	printf 'base\n' > "$R/docs.md"; printf 'archive\n' > "$R/archive.txt"; printf 'other\n' > "$R/other.txt"
	[ -z "${2:-}" ] || ( cd "$R" && eval "$2" )
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# merge: commit what the branch holds and build the merge commit, as GitHub does.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change --allow-empty
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# parents: how many parents the checkout has. A pull request has two.
parents() { git -C "$R" rev-list --parents -n1 HEAD | wc -w | awk '{print $1 - 1}'; }

# ask [event]: what the resolver prints, in $out, its reason in $err, and its
# status in $rc. It runs the repository's own resolver, not the copy planted in the
# base, so a defect planted in the base reaches the guards through git show only.
ask() {
	out="$( cd "$R" && EVENT="${1:-pull_request}" TEST_COMMAND="${TEST_COMMAND_OVERRIDE-$COMMAND}" \
		APT_PACKAGES="$PACKAGES" bash "$RESOLVER" packages 2>"$WORK/err" )"
	rc=$?
	err="$(cat "$WORK/err")"
}
# refused <description> <reason>: the resolver gave up, with that reason, and
# printed no answer the step could use.
refused() {
	check "$1: exit status" "1" "$rc"
	check "$1: nothing on stdout" "" "$out"
	check "$1: the reason" "${FRAGMENT}$2" "${err:0:$((${#FRAGMENT} + ${#2}))}"
}

# --- the baseline: the fixture is a pull request, and an ordinary change is accepted

repo accepted; echo more >> "$R/docs.md"; merge
check "the fixture is a merge commit of two parents" "2" "$(parents)"
ask
check "a docs change selects the editor suite, which needs nothing: exit status" "0" "$rc"
check "and installs no package" "packages=" "$out"
check "and says nothing else" "" "$err"

repo selects; echo more >> "$R/archive.txt"; merge
ask
check "a change the build suite reads installs what that suite needs" "packages=reprepro" "$out"

# --- a diff that cannot be established ------------------------------------------

repo branch-head; echo more >> "$R/docs.md"; git -C "$R" add -A; git -C "$R" commit -qm change
check "the branch head is not a merge: one parent" "1" "$(parents)"
ask
refused "a checkout that is not the merge commit" "no usable PR diff"

repo empty
git -C "$R" commit -q --allow-empty -m empty; git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
check "the empty change is still a merge of two parents" "2" "$(parents)"
ask
refused "a merge that changes nothing" "no usable PR diff"

repo rename; git -C "$R" mv docs.md moved.md; merge
check "the rename is still a merge of two parents" "2" "$(parents)"
ask
refused "a rename, which is two paths and not a safe skip" "no usable PR diff"

# --- an invocation the resolver does not understand ------------------------------

repo invocation; echo more >> "$R/docs.md"; merge
ask push
refused "a push, which has no pull request to narrow" "not a supported PR suite invocation"
TEST_COMMAND_OVERRIDE="./$RUNNER ./$EDITOR"$'\n'"./$BUILD ./$OTHER" ask
refused "a command of two lines, every word of it a valid suite" "not a supported PR suite invocation"
TEST_COMMAND_OVERRIDE="$COMMAND"$'\r' ask
refused "a command with a carriage return" "not a supported PR suite invocation"
CHECK_SUITE_COMPLETENESS_SKIP_FIXTURE_TEST=1 ask
refused "a run that asked the runner to skip its fixture test" "not a supported PR suite invocation"
TEST_COMMAND_OVERRIDE="./$RUNNER" ask
refused "a command that names no suite" "not a supported PR suite invocation"
TEST_COMMAND_OVERRIDE="./$RUNNER ./\$(id).test.sh" ask
refused "a suite path that is not a plain path" "not a supported PR suite invocation"
TEST_COMMAND_OVERRIDE="./$EDITOR ./$BUILD" ask
refused "a command that does not start with the runner" "not a supported PR suite invocation"

# --- what the pull request must not touch ---------------------------------------

repo runner; echo more >> "$R/$RUNNER"; merge
ask
refused "a pull request that edits the runner" "runner or dependency policy changed"

repo policy; echo '# changed' >> "$R/$DEPS"; merge
ask
refused "a pull request that edits the dependency policy" "runner or dependency policy changed"

# --- a map or a classifier in the base that cannot be trusted -----------------------

repo no-scope 'rm -f '"$SCOPE"; echo more >> "$R/docs.md"; merge
ask
refused "a base with no suite map" "Command"
check "and the command that failed is the read of the map" "1" \
	"$(printf '%s' "$err" | grep -q "HEAD^1:$SCOPE" && echo 1 || echo 0)"

repo bad-scope 'printf "%s\n" "'"$EDITOR"'" > '"$SCOPE"; echo more >> "$R/docs.md"; merge
ask
refused "a map with an entry that has no pattern" "unusable suite map"

repo empty-suites 'sed -i "s/for name in suites(.*):/for name in []:/" scripts/quality/scope/ci-job-scope.sh'
echo more >> "$R/docs.md"; merge
ask
refused "a base classifier that selects no suite" "no usable reduced suite decision"

repo unknown-suite 'sed -i "s|for name in suites(.*):|for name in [\"tests/unknown.test.sh\"]:|" scripts/quality/scope/ci-job-scope.sh'
echo more >> "$R/docs.md"; merge
ask
refused "a base classifier that selects a suite nobody listed" "no usable reduced suite decision"

repo noisy "sed -i 's/^def main():/def main():\n    print(\"noise\", file=sys.stderr)/' scripts/quality/scope/ci-job-scope.sh"
echo more >> "$R/docs.md"; merge
ask
refused "a base classifier that answers and also writes to stderr" "no usable reduced suite decision"

repo everything; echo more >> "$R/docs.md"; echo more >> "$R/archive.txt"; echo more >> "$R/other.txt"; merge
ask
refused "a change that selects every suite, so there is nothing to narrow" "no usable reduced suite decision"

# --- a dependency policy in the base that cannot be trusted --------------------------

repo no-policy 'rm -f '"$DEPS"; echo more >> "$R/docs.md"; merge
ask
refused "a base with no dependency policy" "Command"
check "and the command that failed is the read of the policy" "1" \
	"$(printf '%s' "$err" | grep -q "HEAD^1:$DEPS" && echo 1 || echo 0)"

repo no-deps 'printf "%s\n" "'"$EDITOR"'" > '"$DEPS"; echo more >> "$R/docs.md"; merge
ask
refused "an entry that names no dependency" "invalid dependency entry: $EDITOR"

repo twice 'printf "%s -\n" "'"$EDITOR"'" >> '"$DEPS"; echo more >> "$R/docs.md"; merge
ask
refused "a suite listed twice in the policy" "invalid dependency entry: $EDITOR -"

repo imaginary 'printf "%s imaginary-package\n" "'"$EDITOR"'" > '"$DEPS"; echo more >> "$R/docs.md"; merge
ask
refused "a package the caller does not list" "invalid dependency entry: $EDITOR imaginary-package"

repo stranger 'printf "tests/stranger.test.sh -\n" >> '"$DEPS"; echo more >> "$R/docs.md"; merge
ask
refused "an entry for a suite the map does not know" "invalid dependency entry: tests/stranger.test.sh -"

repo unmapped 'sed -i "\|^'"$EDITOR"' |d" '"$DEPS"; echo more >> "$R/docs.md"; merge
ask
refused "a selected suite the policy does not cover" "suite dependencies not established"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
