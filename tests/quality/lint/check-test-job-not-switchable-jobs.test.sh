#!/usr/bin/env bash
# Behaviour tests for the part of scripts/quality/lint/check-test-job-not-switchable.sh
# that reads every job and every step of every workflow, and not only the
# callers of a reusable.
#
# A required check is a job, and the job is the one a pull request can edit:
# `if: false` on the job inside a reusable, on a job a workflow defines itself,
# or on the step that runs the suite leaves the check reporting Success without
# having looked at anything. The cases are of two kinds.
#
#   * Every job and every step of every workflow this repository ships is
#     planted with each switch, a file at a time, and the rule has to refuse it
#     by that switch, naming the file and the job (and the step). The list is
#     the repository's own, so a job added later is held to the rule without
#     anyone adding a case, and the shape of each job is whatever it really is:
#     a caller, a job inside a reusable, a job of a workflow of its own.
#   * The forms that exist on purpose are accepted exactly as they are written
#     and refused when the file, the job or the value differs by one thing.
#
# Every refusal asserts which refusal, and every refusal is paired with the
# acceptance of the same tree before the switch was planted.
#
# Requires: python3 with PyYAML.
# The fixtures are printf templates and carry backticks the assertions read.
# shellcheck disable=SC2016,SC2059
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/lint/check-test-job-not-switchable.sh"
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
run_in() { ( cd "$1" && bash "$SCRIPT" 2>&1 ); }
said() { printf '%s' "$1" | grep -q -F -- "$2" && echo 1 || echo 0; }

# The planter. It copies the workflows of this repository, changes the ones the
# case names, runs the rule on the copy and prints one line per assertion:
# description, expected value, actual value, separated by TAB.
#   plant <file|all> <kind> [job] [step]
# kinds: if, needs, coe (continue-on-error) on the job; step-if and step-coe on
# every step of the job. Without a job, every job of the file is planted at once.
plant() {
	python3 -I - "$HERE" "$SCRIPT" "$WORK" "$@" <<'PY'
import os, shutil, subprocess, sys, yaml

here, script, work, which, kind = sys.argv[1:6]
only_job = sys.argv[6] if len(sys.argv) > 6 else ""
only_step = sys.argv[7] if len(sys.argv) > 7 else ""
source = os.path.join(here, ".github/workflows")
names = sorted(n for n in os.listdir(source) if n.endswith((".yml", ".yaml")))
if which != "all":
    names = [which]
for name in names:
    dest = os.path.join(work, "plant")
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(source, os.path.join(dest, ".github/workflows"))
    rel = ".github/workflows/" + name
    doc = yaml.safe_load(open(os.path.join(source, name)))
    expected = []
    for job_id, job in doc["jobs"].items():
        if only_job and job_id != only_job:
            continue
        uses = job.get("uses") or ""
        local = uses.rsplit("/", 1)[-1] if uses.startswith("./.github/workflows/reusable-") else ""
        who = f"job `{job_id}` in {rel}" + (f" calls `{local}` and" if local else "")
        if kind == "if":
            job["if"] = False
            expected.append((job_id, f"{who} carries a job-level `if:`"))
        elif kind == "needs":
            job["needs"] = "no-such-job"
            expected.append((job_id, f"{who} carries `needs:`"))
        elif kind == "coe":
            job["continue-on-error"] = True
            expected.append((job_id, f"{who} carries `continue-on-error:`"))
        else:
            for number, step in enumerate(job.get("steps") or [], 1):
                label = step.get("name") or step.get("id") or str(step.get("uses") or "").split("@")[0] or f"number {number}"
                if only_step and label != only_step:
                    continue
                key, text = ("if", "an `if:`") if kind == "step-if" else ("continue-on-error", "`continue-on-error:`")
                step[key] = False if key == "if" else True
                expected.append((job_id, f"step `{label}` of job `{job_id}` in {rel} carries {text}"))
    if not expected:
        continue
    with open(os.path.join(dest, rel), "w") as out:
        yaml.safe_dump(doc, out)
    done = subprocess.run(["bash", script], cwd=dest, capture_output=True, text=True)
    said = done.stdout + done.stderr
    print(f"{name}: planting {kind} is refused\t1\t{done.returncode}")
    for job_id, needle in expected:
        print(f"{name}: {job_id}: {needle}\t1\t{1 if needle in said else 0}")
PY
}

assert_planted() { # same arguments as plant
	local desc expected actual
	while IFS=$'\t' read -r desc expected actual; do
		check "$desc" "$expected" "$actual"
	done < <(plant "$@")
}

# --- the repository's own workflows are the positive control ---------------
d="$(new)"
cp "$HERE"/.github/workflows/*.yml "$d/.github/workflows/"
out="$(run_in "$d")"; rc=$?
check "every workflow this repository ships is accepted" "0" "$rc"
check "and the step says no job or step carries a switch" "1" \
	"$(said "$out" 'no job or step of any workflow carries a switch')"

# --- every job, every step, every switch ------------------------------------
for kind in if needs coe step-if step-coe; do
	assert_planted all "$kind"
done

# ===========================================================================
# The jobs that define a check, one shape at a time
# ===========================================================================
#
# Each tree carries a sound caller of reusable-shell-ci, so the one defect in it
# is the one the case plants.

workflow() { # $1=dir $2=file $3=body
	printf '%s\n' "$3" > "$1/.github/workflows/$2"
}
sound() { cp "$HERE/.github/workflows/tests.yml" "$1/.github/workflows/"; }

ALARM=$'name: Health\non: schedule\njobs:\n  check:\n    name: Check published archive\n%s    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'

# A job a workflow defines itself, with the shape of the alarm of a scheduled
# health check.
d="$(new)"; sound "$d"; printf -v body "$ALARM" ''; workflow "$d" health-check.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a job of its own with no switch is accepted" "0" "$rc"

d="$(new)"; sound "$d"; printf -v body "$ALARM" $'    if: false\n'; workflow "$d" health-check.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the alarm of a scheduled workflow switched off with if: false is refused" "1" "$rc"
check "and the refusal names that file and that job" "1" \
	"$(said "$out" 'job `check` in .github/workflows/health-check.yml carries a job-level `if:`')"
check "and it says where a condition on purpose is declared" "1" \
	"$(said "$out" 'CONDITIONAL_JOBS of this script')"
check "and the sound caller is not blamed" "0" "$(said "$out" 'in .github/workflows/tests.yml')"

for form in $'    if:\n' $'    if: \'\'\n' $'    if: ${{ false }}\n' $'    if: true\n'; do
	d="$(new)"; sound "$d"; printf -v body "$ALARM" "$form"; workflow "$d" health-check.yml "$body"
	out="$(run_in "$d")"; rc=$?
	check "a job of its own with an if: that is no listed form ($(printf '%s' "$form" | tr -d '\n ')) is refused" "1" "$rc"
	check "and it is refused for the if:, naming the job" "1" \
		"$(said "$out" 'job `check` in .github/workflows/health-check.yml carries a job-level `if:`')"
done

d="$(new)"; sound "$d"; printf -v body "$ALARM" $'    needs: setup\n'; workflow "$d" health-check.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a job of its own with needs: is refused" "1" "$rc"
check "and it is refused for the needs:, naming the job" "1" \
	"$(said "$out" 'job `check` in .github/workflows/health-check.yml carries `needs:`')"

d="$(new)"; sound "$d"; printf -v body "$ALARM" $'    continue-on-error: true\n'; workflow "$d" health-check.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a job of its own with continue-on-error: is refused" "1" "$rc"
check "and it is refused for the continue-on-error:, naming the job" "1" \
	"$(said "$out" 'job `check` in .github/workflows/health-check.yml carries `continue-on-error:`')"

# A job that needs a job that can be skipped is skipped with it. The scope job
# of freshness.yml is skipped outside a pull request, on purpose; what waits for
# it has to say so in a form the rule lists.
SCOPE=$'name: Freshness\non: pull_request\njobs:\n  scope:\n    if: github.event_name == \'pull_request\'\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  later:\n%s    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
d="$(new)"; sound "$d"; printf -v body "$SCOPE" ''; workflow "$d" freshness.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a job that waits for nothing, beside the scope job, is accepted" "0" "$rc"

d="$(new)"; sound "$d"; printf -v body "$SCOPE" $'    needs: scope\n'; workflow "$d" freshness.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a job that needs a job that can be skipped is refused" "1" "$rc"
check "and it is refused for the needs:, naming the job" "1" \
	"$(said "$out" 'job `later` in .github/workflows/freshness.yml carries `needs:`')"
check "and the scope job, whose condition is listed, is not blamed" "0" \
	"$(said "$out" 'job `scope`')"

# --- a condition on purpose is accepted by its exact form ------------------
EMPTY=$'name: Empty diff\non:\n  workflow_call:\njobs:\n  %s:\n    name: empty diff\n    if: %s\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
PR="github.event_name == 'pull_request'"

d="$(new)"; sound "$d"; printf -v body "$EMPTY" empty-diff "$PR"; workflow "$d" reusable-empty-diff.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the empty diff job with its own condition is accepted" "0" "$rc"

d="$(new)"; sound "$d"; printf -v body "$EMPTY" empty-diff "github.event_name != 'pull_request'"; workflow "$d" reusable-empty-diff.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the empty diff job with another condition is refused" "1" "$rc"
check "and it is refused for the if:, naming the job and the file" "1" \
	"$(said "$out" 'job `empty-diff` in .github/workflows/reusable-empty-diff.yml carries a job-level `if:`')"

d="$(new)"; sound "$d"; printf -v body "$EMPTY" other "$PR"; workflow "$d" reusable-empty-diff.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the same condition on another job of that file is refused" "1" "$rc"
check "and it is refused for the if:, naming that job" "1" \
	"$(said "$out" 'job `other` in .github/workflows/reusable-empty-diff.yml carries a job-level `if:`')"

d="$(new)"; sound "$d"; printf -v body "$EMPTY" empty-diff "$PR"; workflow "$d" renamed.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the same job and condition in another file is refused" "1" "$rc"
check "and it is refused for the if:, naming that file" "1" \
	"$(said "$out" 'job `empty-diff` in .github/workflows/renamed.yml carries a job-level `if:`')"

# The condition of the job that runs the tests is the one it has, and a caller
# of the reusable keeps no way to make it skip.
d="$(new)"; sound "$d"
cp "$HERE/.github/workflows/reusable-shell-ci.yml" "$d/.github/workflows/"
out="$(run_in "$d")"; rc=$?
check "the shell reusable as it ships is accepted beside its caller" "0" "$rc"
sed -i "s/^    if: inputs.test-command != ''\$/    if: inputs.test-command != '' \&\& false/" "$d/.github/workflows/reusable-shell-ci.yml"
out="$(run_in "$d")"; rc=$?
check "the job that runs the tests with a condition that can never hold is refused" "1" "$rc"
check "and it is refused for the if:, naming the reusable and the job" "1" \
	"$(said "$out" 'job `test` in .github/workflows/reusable-shell-ci.yml carries a job-level `if:`')"

# --- the step that runs the check -------------------------------------------
assert_planted reusable-shell-ci.yml step-if test "Run tests"
assert_planted reusable-shell-ci.yml step-if shellcheck "Run shellcheck"
assert_planted reusable-workflow-lint.yml step-if workflow-lint "A required test job must not be switchable off"
assert_planted reusable-line-limit.yml step-if line-limit "Check file lengths"

STEPS=$'name: Direct\non: pull_request\njobs:\n  compare:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Compare with the generator\n%s        run: true\n'
d="$(new)"; sound "$d"; printf -v body "$STEPS" ''; workflow "$d" direct.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a step with no condition is accepted" "0" "$rc"

d="$(new)"; sound "$d"; printf -v body "$STEPS" $'        if: false\n'; workflow "$d" direct.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the step that runs the comparison switched off with if: false is refused" "1" "$rc"
check "and the refusal names the step, the job and the file" "1" \
	"$(said "$out" 'step `Compare with the generator` of job `compare` in .github/workflows/direct.yml carries an `if:`')"
check "and it says where a condition on purpose is declared" "1" "$(said "$out" 'STEP_CONDITIONS of this script')"

d="$(new)"; sound "$d"; printf -v body "$STEPS" $'        continue-on-error: true\n'; workflow "$d" direct.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the step that runs the comparison allowed to fail is refused" "1" "$rc"
check "and it is refused for the continue-on-error:, naming the step" "1" \
	"$(said "$out" 'step `Compare with the generator` of job `compare` in .github/workflows/direct.yml carries `continue-on-error:`')"

# A listed condition belongs to its job: the same value on a step of another job
# is not a licence.
d="$(new)"; sound "$d"; printf -v body "$STEPS" $'        if: steps.scope.outputs.needed != \'false\'\n'; workflow "$d" direct.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a condition another job may carry, on a step of a job that may not, is refused" "1" "$rc"
check "and it is refused for the if:, naming the job" "1" \
	"$(said "$out" 'step `Compare with the generator` of job `compare` in .github/workflows/direct.yml carries an `if:`')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
