#!/usr/bin/env bash
# Step-level switches on every step of every workflow: an `if:` that the
# list of the job does not name, and any `continue-on-error:`.
#
# The step is the one that runs the suite, the comparison or the script of the
# check, so a condition on it skips the check as surely as one on the job does
# while the job and its name still report Success. Every step of every workflow
# this repository ships is planted with each step-level switch and the rule has
# to refuse it, naming the file, the job and the step; the steps that run the
# check are planted by name, and a step of a job that may not carry a condition
# is refused for one that another job may carry.
#
# Every refusal asserts which refusal, and every refusal is paired with the
# acceptance of the same tree before the switch was planted.
#
# Requires: python3 with PyYAML.
# The fixtures are printf templates and carry backticks the assertions read.
# shellcheck disable=SC2016,SC2059
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091 # the fixture of the suites of this rule
. "$HERE/tests/fixtures/ci/switchable-rule.sh"

# --- every step, every step-level switch ------------------------------------
for kind in step-if step-coe; do
	assert_planted all "$kind"
done

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


finish
