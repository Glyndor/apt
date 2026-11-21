#!/usr/bin/env bash
#
# Tests for scripts/quality/coverage/check-suites-wired.sh, the check that every suite
# under tests/ is run by a workflow on a pull request, and for the step of
# .github/workflows/reusable-workflow-lint.yml that runs it from outside the
# test job.
#
# Each case builds a small tree with three suites and a workflow, changes one
# thing and reads which suite the check names and why. A rejection asserts
# its reason, and every refusal has a passing tree of the same shape beside
# it, so a fixture that fails for another reason cannot pass for this one.
#
# Requires: python3 with PyYAML, git.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE="$HERE/scripts/quality/coverage/check-suites-wired.sh"
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
said() { printf '%s' "$out" | grep -cF -- "$1"; }

WATCHER=tests/ci/suites/ci-runs-every-test.test.sh
SUITES="./tests/a.test.sh ./$WATCHER ./tests/area/b.test.sh"

# tree <dir> <test-command> [extra workflow text]: three suites and a tests.yml
# whose shell job runs the given command.
tree() {
	local dir="$WORK/$1"
	rm -rf "$dir"; mkdir -p "$dir/tests/area" "$dir/tests/ci/suites" "$dir/.github/workflows"
	: > "$dir/tests/a.test.sh"; : > "$dir/tests/area/b.test.sh"; : > "$dir/$WATCHER"
	printf 'on:\n  pull_request:\n  push:\njobs:\n  shell:\n    uses: ./.github/workflows/reusable-shell-ci.yml\n    with:\n      test-command: "%s"\n%s' \
		"$2" "${3:-}" > "$dir/.github/workflows/tests.yml"
	echo "$dir"
}
# gate <dir> [exemptions] [base exemptions]: the exemptions are written to the
# tree's list, and a base list, when given, is handed over as the step does.
gate() {
	local base=""
	if [ -n "${2:-}" ]; then
		mkdir -p "$1/scripts/quality/coverage"; printf '%s\n' "$2" > "$1/scripts/quality/coverage/suite-exemptions.txt"
	fi
	if [ -n "${3+set}" ]; then base="$WORK/base-exemptions"; printf '%s\n' "$3" > "$base"; fi
	out="$(SUITE_EXEMPTIONS_BASE="$base" bash "$GATE" "$1" 2>&1)"; rc=$?
}

# --- the green case, and a suite or the watcher dropped ---------------------

gate "$(tree green "$SUITES")"
check "a tree whose every suite is in the test-command passes" "0" "$rc"
check "and says how many suites it saw" "1" "$(said '3 suite(s) under tests/ are run')"

gate "$(tree one "./tests/a.test.sh ./$WATCHER")"
check "a suite missing from the test-command fails" "1" "$rc"
check "and is named, with the reason" "1" \
	"$(said 'tests/area/b.test.sh is not run by any workflow on a pull request (it is named nowhere)')"
check "and the suites that are run are not named" "1" "$(said 'is not run by any workflow')"

gate "$(tree watcher "./tests/a.test.sh")"
check "dropping the watcher with another suite fails" "1" "$rc"
check "and the watcher is named as the watcher" "1" \
	"$(said "$WATCHER, the watcher inside the test job, is itself not run")"
check "and the other dropped suite is named too" "1" "$(said 'tests/area/b.test.sh is not run')"

gate "$(tree empty "")"
check "an emptied test-command fails for every suite" "3" "$(said 'is not run by any workflow')"

# --- a step that runs a suite, and the places a pull request can skip ------

step() { printf '  other:\n    runs-on: x\n%s    steps:\n      - run: |\n          # ./tests/area/b.test.sh is prose here\n          %s\n%s' \
	"${3:-}" "$1" "${2:-}"; }
gate "$(tree step "./tests/a.test.sh ./$WATCHER" "$(step 'bash ./tests/area/b.test.sh --quiet')")"
check "a suite run from a step's run: counts" "0" "$rc"

RUNNER=tests/ci/suites/check-suite-completeness.test.sh
gate "$(tree runner-arg "./tests/a.test.sh ./$WATCHER" "$(step "./$RUNNER ./tests/area/b.test.sh")")"
check "a suite handed to the suite runner in a step counts" "0" "$rc"

gate "$(tree other-arg "./tests/a.test.sh ./$WATCHER" "$(step './tests/a.test.sh ./tests/area/b.test.sh')")"
check "a suite handed to a script that is not the suite runner does not count" "1" \
	"$(said 'tests/area/b.test.sh is not run')"

gate "$(tree prose "./tests/a.test.sh ./$WATCHER" "$(step 'echo ./tests/area/b.test.sh')")"
check "a suite only named in a comment or an echo does not count" "1" "$(said 'tests/area/b.test.sh is not run')"

gate "$(tree step-if "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '        if: false')")"
check "a suite in a step with if: does not count" "1" \
	"$(said "tests/area/b.test.sh is not run by any workflow on a pull request (tests.yml#other: the step has an \`if:\`)")"

gate "$(tree step-coe "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '        continue-on-error: true')")"
check "a suite in a step that may fail does not count" "1" "$(said 'tests.yml#other: the step may fail')"

gate "$(tree job-if "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '' '    if: github.actor == 1
')")"
check "a suite in a job with if: does not count" "1" "$(said "tests.yml#other: the job has an \`if:\`")"

# The reviewed bypass: the test job needs a job that is switched off, so
# GitHub skips both and the skipped check reports Success.
gate "$(tree needs "$SUITES" '    needs: noop
  noop:
    if: false
    runs-on: x
    steps: [{run: echo hi}]
')"
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "the suites of a caller with needs: do not count" "3" \
	"$(said 'tests.yml#shell: the job has `needs:`, and is skipped when a job it needs is')"

gate "$(tree step-needs "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '' '    needs: shell
')")"
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "a suite in a step of a job with needs: does not count" "1" "$(said 'tests.yml#other: the job has `needs:`')"

# A line whose verdict a shell operator can throw away does not count, nor
# does a block that may hold the path as data or runs without errexit.
# shellcheck disable=SC2016,SC1003 # the suffixes are literal shell text, never expanded here
for tail in ' || true' ' && :' ' | tee log' ' &' ' ; true' ' > /dev/null' ' 2>&1' ' $(true)' ' \'; do
	gate "$(tree "op" "./tests/a.test.sh ./$WATCHER" "$(step "./tests/area/b.test.sh$tail")")"
	check "a suite followed by '$tail' does not count" "1" \
		"$(said 'tests.yml#other: the line goes on with a shell operator')"
done
gate "$(tree args "./tests/a.test.sh ./$WATCHER" "$(step "./$RUNNER ./tests/area/b.test.sh --quiet")")"
check "control: a line with plain arguments still counts" "0" "$rc"
gate "$(tree heredoc "./tests/a.test.sh ./$WATCHER" "$(step "cat <<'EOF' > list
          ./tests/area/b.test.sh
          EOF")")"
check "a suite inside a here-doc does not count" "1" "$(said 'tests.yml#other: the step'"'"'s run: holds a here-doc')"
gate "$(tree set-e "./tests/a.test.sh ./$WATCHER" "$(step "set +e
          ./tests/area/b.test.sh")")"
check "a suite in a block that turns errexit off does not count" "1" "$(said 'tests.yml#other: the step turns errexit off')"
gate "$(tree pwsh "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '        shell: pwsh')")"
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "a suite in a step under another shell does not count" "1" "$(said 'the step runs under `shell: pwsh`')"
gate "$(tree job-shell "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '' '    defaults: {run: {shell: pwsh}}
')")"
check "a job whose default shell is another does not count" "1" "$(said 'tests.yml#other: the step runs under')"
dir="$(tree wf-shell "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh')")"
sed -i 's/^jobs:$/defaults: {run: {shell: pwsh}}\njobs:/' "$dir/.github/workflows/tests.yml"
gate "$dir"
check "a workflow whose default shell is another does not count" "1" "$(said 'tests.yml#other: the step runs under')"
gate "$(tree bash-shell "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '        shell: bash')")"
check "control: shell: bash still counts" "0" "$rc"

# A skip list that matches the workflow, a script or a suite lets the pull
# request that widens it skip the suite that would have refused it.
# The match is the reusable's: bash, where `[^x]` is a negated class, extglob
# is on and `*` crosses a `/`. fnmatch reads the last three as matching
# nothing here, which is the gap a second grammar would leave.
for skip in '*' 'tests/**' '.github/*' 'docs/** scripts/*' '[^x]*' '@(.github|tests)/*' '*(?)' 'docs/*.md scripts*'; do
	dir="$(tree skip "$SUITES" "      skip-suite-paths: \"$skip\"
")"; mkdir -p "$dir/scripts"; : > "$dir/scripts/x.sh"
	gate "$dir"
	check "a caller whose skip-suite-paths is '$skip' counts no suite" "3" \
		"$(said 'tests.yml#shell: its skip-suite-paths')"
done
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "and the message names the pattern that matched and a file it matches" "3" \
	"$(said 'skip-suite-paths `scripts*` matches scripts/x.sh')"
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "and not the pattern of the list that matched nothing" "0" "$(said 'skip-suite-paths `docs/*.md`')"
# The list reaches bash as data: a pattern that reads like a command is a
# pattern, and runs nothing.
# shellcheck disable=SC2016 # the command text is the literal pattern under test
dir="$(tree skip-inject "$SUITES" '      skip-suite-paths: "$(touch${IFS}injected) `touch${IFS}injected`"
')"
# Run from inside the tree, so a command that did run would leave its file there.
out="$(cd "$dir" && bash "$GATE" "$dir" 2>&1)"; rc=$?
check "a skip pattern is never run as a command" "0" "$(find "$dir" -name injected | wc -l)"
check "and, matching nothing, leaves every suite counted" "0" "$rc"
gate "$(tree skip-docs "$SUITES" '      skip-suite-paths: "docs/** README.md"
')"
check "control: a skip list of prose only still counts every suite" "0" "$rc"

gate "$(tree wd "./tests/a.test.sh ./$WATCHER" "$(step './tests/area/b.test.sh' '        working-directory: sub')")"
check "a suite run from another working directory is not the top-level one" "1" \
	"$(said 'tests/area/b.test.sh is not run')"

dir="$(tree filter "$SUITES")"
sed -i 's/^  pull_request:$/  pull_request:\n    paths: [docs\/**]/' "$dir/.github/workflows/tests.yml"
gate "$dir"
check "a workflow with a path filter on pull_request does not count" "3" \
	"$(said 'tests.yml#shell: the workflow does not run on every pull request')"

dir="$(tree cron "$SUITES")"
sed -i 's/^  pull_request:$/  schedule: [{cron: "0 0 * * *"}]/' "$dir/.github/workflows/tests.yml"
gate "$dir"
check "a workflow without pull_request does not count" "3" "$(said 'does not run on every pull request')"

# --- exemptions ---------------------------------------------------------------

dir="$(tree exempt "./tests/a.test.sh ./$WATCHER")"
gate "$dir" "tests/area/b.test.sh: needs a device the runner does not have"
check "an exempt suite with a reason passes" "0" "$rc"
check "and the exemption and its reason are printed" "1" \
	"$(said 'exempt: tests/area/b.test.sh: needs a device the runner does not have')"

gate "$dir" "tests/area/b.test.sh: needs a device
tests/area/gone.test.sh: was split into two"
check "an exemption for a file that does not exist fails" "1" "$rc"
check "and says the file does not exist" "1" \
	"$(said 'the exemption for tests/area/gone.test.sh names a file that does not exist')"

gate "$dir" "tests/area/b.test.sh:"
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "an exemption without a reason fails" "1" "$(said 'is not `tests/<path>.test.sh: <reason>`')"

gate "$(tree exempt-wired "$SUITES")" "tests/area/b.test.sh: once needed a device"
check "an exemption for a suite that is run is not a failure" "0" "$rc"
check "but is reported as having no effect" "1" \
	"$(said '::warning::tests/area/b.test.sh is exempt but a workflow runs it')"

# The list on the base commit decides what a pull request may exempt.
dir="$(tree exempt-base "./tests/a.test.sh ./$WATCHER")"
gate "$dir" "tests/area/b.test.sh: needs a device" "# nothing exempt on the base"
check "an exemption the pull request adds does not count yet" "1" "$(said 'tests/area/b.test.sh is not run')"
check "and is reported as pending" "1" "$(said 'pending: tests/area/b.test.sh is exempt once this list is on the base branch')"
gate "$dir" "tests/area/b.test.sh: needs a device" "tests/area/b.test.sh: needs a device"
check "control: the same exemption on the base commit counts" "0" "$rc"
gate "$dir" "# the pull request removed it" "tests/area/b.test.sh: needs a device"
check "an exemption the pull request removes stops counting at once" "1" "$(said 'tests/area/b.test.sh is not run')"
out="$(SUITE_EXEMPTIONS_BASE="$WORK/no-such-list" bash "$GATE" "$dir" 2>&1)"
check "a base list that cannot be read fails" "1" "$(said 'cannot read the base copy of scripts/quality/coverage/suite-exemptions.txt')"

# --- nothing to read is a failure, not a pass --------------------------------

dir="$(tree none "$SUITES")"; rm -rf "$dir/tests"
gate "$dir"
check "a tree with no suite fails rather than passing" "1" "$rc"
check "and says it found nothing to check" "1" "$(said 'no tests/**/*.test.sh found')"

dir="$(tree broken "$SUITES")"; printf 'jobs: [\n' > "$dir/.github/workflows/broken.yml"
gate "$dir"
check "a workflow that cannot be parsed fails" "1" "$(said 'cannot read .github/workflows/broken.yml')"

# --- the real repository --------------------------------------------------------
#
# With its own list of exemptions, which the checker reads from the tree.
gate "$HERE"
check "every suite of this repository is run by a workflow" "0" "$rc"

# --- the workflow step reads the checker from the base commit -----------------
#
# The step is cut out of the reusable as it ships and run over a merge commit,
# the shape a pull request is checked out in. The pull request drops a suite
# and replaces the checker with one that passes everything: the base copy has
# to be the one that decides.

# The step that takes the scripts from the base commit runs first, and the
# check runs the copy it took, so both are cut out and run in that order.
python3 -I - "$HERE/.github/workflows/reusable-workflow-lint.yml" > "$WORK/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["workflow-lint"]["steps"]
for name in ("Take the rule scripts from the base commit", "Every suite is run by a workflow"):
    print(next(s for s in steps if s.get("name") == name)["run"])
PY
check "the steps were extracted from the workflow" "1" "$(grep -c 'lint-rules/check-suites-wired.sh' "$WORK/step.sh")"

# What the extracted bodies cannot show: both steps run on every event, whatever
# the scope decision; the first is handed the event and the base commit the
# event names, and no input of the caller, which the pull request controls,
# reaches either of them.
wiring="$(python3 -I - "$HERE/.github/workflows/reusable-workflow-lint.yml" <<'PY'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
steps = spec["jobs"]["workflow-lint"]["steps"]
take = next(s for s in steps if s.get("name") == "Take the rule scripts from the base commit")
step = next(s for s in steps if s.get("name") == "Every suite is run by a workflow")
print("if" in take, sorted(take.get("env", {}).items()), "inputs." in take["run"],
      "if" in step, sorted(step.get("env", {}).items()), "inputs." in step["run"],
      steps.index(take) < steps.index(step))
PY
)"
check "the steps have no condition, read the event and its base commit, and no caller input" \
	"False [('BASE_SHA', '\${{ github.event.pull_request.base.sha }}'), ('EVENT', '\${{ github.event_name }}')] False False [] False True" "$wiring"

repo="$(tree repo "$SUITES")"
git() { command git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
merge_pr() { # <base> <tests.yml command> <checker body or empty to delete> [exemptions]
	git checkout -q -B main "$1"; git checkout -q -B pr
	[ -z "${4:-}" ] || printf '%s\n' "$4" > "$repo/scripts/quality/coverage/suite-exemptions.txt"
	sed -i "s#^      test-command: .*#      test-command: \"$2\"#" "$repo/.github/workflows/tests.yml"
	mkdir -p "$repo/scripts/quality/coverage"
	if [ -n "$3" ]; then printf '%s\n' "$3" > "$repo/scripts/quality/coverage/check-suites-wired.sh"
	else rm -f "$repo/scripts/quality/coverage/check-suites-wired.sh"; fi
	git add -A; git commit -qm pr; git checkout -q main
	git merge -q --no-ff pr -m merge
}
# The base the event names is the merge commit's first parent unless a case
# says otherwise, which is what a pull request is checked out as.
run_step() { # <event> [base sha]
	rm -rf "$WORK/rt"; mkdir -p "$WORK/rt"
	out="$(cd "$repo" && EVENT="$1" BASE_SHA="${2-$(git rev-parse HEAD^1)}" RUNNER_TEMP="$WORK/rt" \
		bash -e -o pipefail "$WORK/step.sh" 2>&1)"; rc=$?
}
git init -q -b main
mkdir -p "$repo/scripts/quality/coverage" "$repo/scripts/quality/lint"; cp "$GATE" "$repo/scripts/quality/coverage/"
# The other two scripts the first step takes; this suite exercises only the checker.
printf '#!/usr/bin/env bash\n' > "$repo/scripts/quality/lint/check-test-job-not-switchable.sh"
printf '#!/usr/bin/env bash\n' > "$repo/scripts/quality/lint/check-tooling-isolation.sh"
printf '# nothing exempt\n' > "$repo/scripts/quality/coverage/suite-exemptions.txt"
git add -A; git commit -qm base; base="$(git rev-parse HEAD)"

merge_pr "$base" "./tests/a.test.sh ./$WATCHER" "exit 0"
run_step pull_request
check "a pull request that drops a suite and disarms the checker still fails" "1" "$rc"
check "because the base checker names the suite" "1" "$(said 'tests/area/b.test.sh is not run')"
merge_pr "$base" "./tests/a.test.sh ./$WATCHER" "$(cat "$GATE")" "tests/area/b.test.sh: dropped on purpose"
run_step pull_request
check "a pull request that drops a suite and exempts it in the same change still fails" "1" "$rc"
check "because the base list does not carry the exemption" "1" "$(said 'pending: tests/area/b.test.sh')"
run_step push
check "control: on a push the checkout's list decides" "0" "$rc"
merge_pr "$base" "./tests/a.test.sh ./$WATCHER" "exit 0"
run_step push
check "control: on a push the checkout's copy decides, and that one was disarmed" "0" "$rc"

git checkout -q -B main "$base"; git rm -q scripts/quality/coverage/check-suites-wired.sh; git commit -qm before
merge_pr "$(git rev-parse HEAD)" "./tests/a.test.sh ./$WATCHER" "$(cat "$GATE")"
run_step pull_request
check "a base without the checker uses the pull request's copy" "1" "$(said 'tests/area/b.test.sh is not run')"

merge_pr "$base" "$SUITES" ""
run_step push
check "a checkout without the checker fails" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# A pull request of two commits, checked out at its own head rather than at the
# merge: HEAD^1 is then the pull request's first commit, which disarms the
# checker. The base the event names is what decides, not HEAD^1.
git checkout -q -B pr "$base"
printf 'exit 0\n' > "$repo/scripts/quality/coverage/check-suites-wired.sh"
git add -A; git commit -qm 'disarm the checker'
sed -i "s#^      test-command: .*#      test-command: \"./tests/a.test.sh ./$WATCHER\"#" "$repo/.github/workflows/tests.yml"
git add -A; git commit -qm 'drop a suite'
run_step pull_request "$base"
check "a pull request whose HEAD^1 is its own commit is judged by the base the event names" "1" "$rc"
check "and the base's checker names the suite" "1" "$(said 'tests/area/b.test.sh is not run')"
run_step pull_request "$(printf '%040d' 0)"
check "a base commit that cannot be read fails the step" "1" "$rc"
check "and says it could not fetch it" "1" "$(said 'Could not fetch the base commit')"
run_step pull_request ""
check "a pull request event with no base commit fails the step" "1" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
