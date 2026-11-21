#!/usr/bin/env bash
#
# Tests for scripts/quality/check-suites-wired.sh, the check that every suite
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

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$HERE/scripts/quality/check-suites-wired.sh"
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
gate() { out="$(SUITE_EXEMPTIONS="${2:-}" bash "$GATE" "$1" 2>&1)"; rc=$?; }

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
check "an exemption without a reason fails" "1" "$(said 'is not `tests/<path>.test.sh: <reason>`')"

gate "$(tree exempt-wired "$SUITES")" "tests/area/b.test.sh: once needed a device"
check "an exemption for a suite that is run fails" "1" \
	"$(said 'tests/area/b.test.sh is exempt but a workflow runs it')"

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
# With the exemptions its own workflow-lint caller passes, so an exemption
# added there is read here too.
exemptions="$(python3 -I -c 'import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"].values()
print(next(j for j in jobs if "reusable-workflow-lint" in j.get("uses", "")).get("with", {}).get("suite-exemptions", ""))' \
	"$HERE/.github/workflows/workflow-lint.yml")"
gate "$HERE" "$exemptions"
check "every suite of this repository is run by a workflow" "0" "$rc"

# --- the workflow step reads the checker from the base commit -----------------
#
# The step is cut out of the reusable as it ships and run over a merge commit,
# the shape a pull request is checked out in. The pull request drops a suite
# and replaces the checker with one that passes everything: the base copy has
# to be the one that decides.

python3 -I - "$HERE/.github/workflows/reusable-workflow-lint.yml" > "$WORK/step.sh" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: Every suite is run by a workflow" in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if line.strip() and not line.startswith(" " * 10):
        break
    body.append(line[10:])
print("\n".join(body))
PY
check "the step was extracted from the workflow" "1" "$(grep -c 'check-suites-wired.sh' "$WORK/step.sh")"

# What the extracted body cannot show: the step runs on every event, whatever
# the scope decision, and it is handed the event and the caller's exemptions.
wiring="$(python3 -I - "$HERE/.github/workflows/reusable-workflow-lint.yml" <<'PY'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
inputs = spec[True]["workflow_call"]["inputs"]
step = next(s for s in spec["jobs"]["workflow-lint"]["steps"]
            if s.get("name") == "Every suite is run by a workflow")
print("if" in step, step.get("env", {}).get("EVENT"), step.get("env", {}).get("SUITE_EXEMPTIONS"),
      repr(inputs["suite-exemptions"].get("default")))
PY
)"
check "the step has no condition and gets the event and the exemptions" \
	"False \${{ github.event_name }} \${{ inputs.suite-exemptions }} ''" "$wiring"

repo="$(tree repo "$SUITES")"
git() { command git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
merge_pr() { # <base> <tests.yml command> <checker body or empty to delete>
	git checkout -q -B main "$1"; git checkout -q -B pr
	sed -i "s#^      test-command: .*#      test-command: \"$2\"#" "$repo/.github/workflows/tests.yml"
	mkdir -p "$repo/scripts/quality"
	if [ -n "$3" ]; then printf '%s\n' "$3" > "$repo/scripts/quality/check-suites-wired.sh"
	else rm -f "$repo/scripts/quality/check-suites-wired.sh"; fi
	git add -A; git commit -qm pr; git checkout -q main
	git merge -q --no-ff pr -m merge
}
run_step() { out="$(cd "$repo" && EVENT="$1" SUITE_EXEMPTIONS="${2:-}" RUNNER_TEMP="$WORK" bash "$WORK/step.sh" 2>&1)"; rc=$?; }
git init -q -b main
mkdir -p "$repo/scripts/quality"; cp "$GATE" "$repo/scripts/quality/"
git add -A; git commit -qm base; base="$(git rev-parse HEAD)"

merge_pr "$base" "./tests/a.test.sh ./$WATCHER" "exit 0"
run_step pull_request
check "a pull request that drops a suite and disarms the checker still fails" "1" "$rc"
check "because the base checker names the suite" "1" "$(said 'tests/area/b.test.sh is not run')"
run_step pull_request "tests/area/b.test.sh: needs a device"
check "and the step hands the caller's exemptions to the checker" "0" "$rc"
run_step push
check "control: on a push the checkout's copy decides, and that one was disarmed" "0" "$rc"

git checkout -q -B main "$base"; git rm -q scripts/quality/check-suites-wired.sh; git commit -qm before
merge_pr "$(git rev-parse HEAD)" "./tests/a.test.sh ./$WATCHER" "$(cat "$GATE")"
run_step pull_request
check "a base without the checker uses the pull request's copy" "1" "$(said 'tests/area/b.test.sh is not run')"

merge_pr "$base" "$SUITES" ""
run_step push
check "a checkout without the checker fails" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
