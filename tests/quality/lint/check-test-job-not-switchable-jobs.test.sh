#!/usr/bin/env bash
# Job-level switches on every job of every workflow: the part of
# scripts/quality/lint/check-test-job-not-switchable.sh that reads the jobs, and not only the callers of a reusable.
#
# A required check is a job, and the job is the one a pull request can edit:
# `if: false` on the job inside a reusable, or on a job a workflow defines
# itself, leaves the check reporting Success without having looked at anything.
# The cases are of two kinds.
#
#   * Every job of every workflow this repository ships is planted with each
#     job-level switch, a file at a time, and the rule has to refuse it by that
#     switch, naming the file and the job. The list is the repository's own, so a
#     job added later is held to the rule without anyone adding a case, and the
#     shape of each job is whatever it really is: a caller, a job inside a
#     reusable, a job of a workflow of its own.
#   * The forms that exist on purpose are accepted exactly as they are written
#     and refused when the file, the job or the value differs by one thing.
#
# The step-level switches are in ...-steps.test.sh, what a condition reads in
# ...-pins.test.sh, ...-context.test.sh and ...-checkout.test.sh.
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

# --- the repository's own workflows are the positive control ---------------
d="$(new)"
cp "$HERE"/.github/workflows/*.yml "$d/.github/workflows/"
out="$(run_in "$d")"; rc=$?
check "every workflow this repository ships is accepted" "0" "$rc"
check "and the step says no job or step carries a switch" "1" \
	"$(said "$out" 'no job or step of any workflow carries a switch')"


# --- every job, every job-level switch ---------------------------------------
for kind in if needs coe; do
	assert_planted all "$kind"
done

# ===========================================================================
# The jobs that define a check, one shape at a time
# ===========================================================================
#
# Each tree carries a sound caller of reusable-shell-ci, so the one defect in it
# is the one the case plants.

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

# A form lists the keys it allows and no others: a key the form lacks is
# refused even when it has no value, which YAML reads as null and which equals
# the null of a key that is not there.
d="$(new)"; sound "$d"; printf -v body "$EMPTY" empty-diff "$PR"; body="${body/runs-on:/needs:
    runs-on:}"; workflow "$d" reusable-empty-diff.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the empty diff job with a needs: with no value is refused" "1" "$rc"
check "and it is refused for the needs:" "1" \
	"$(said "$out" 'job `empty-diff` in .github/workflows/reusable-empty-diff.yml carries `needs:`')"

UPDATE=$'name: Update\non: schedule\njobs:\n  render:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  validate:\n    needs: render\n%s    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
d="$(new)"; sound "$d"; printf -v body "$UPDATE" ''; workflow "$d" update.yml "$body"
out="$(run_in "$d")"; rc=$?
check "a job that waits for the job it is listed to wait for is accepted" "0" "$rc"
d="$(new)"; sound "$d"; printf -v body "$UPDATE" $'    if:\n'; workflow "$d" update.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the same job with an if: with no value is refused" "1" "$rc"
check "and it is refused for the if:" "1" \
	"$(said "$out" 'job `validate` in .github/workflows/update.yml carries a job-level `if:`')"

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

# The gate of audit.yml keeps its whole form. Listing `needs:` and `if:` apart would
# let a gate lose its `if: always()` and keep passing the rule: the gate is then
# skipped when a requirement fails, and GitHub counts that as passed.
GATE=$'name: Audit\non: pull_request\njobs:\n  scope:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  audit:\n    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.run_audit != \'false\' }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  gate:\n    name: audit gate\n%s    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
d="$(new)"; sound "$d"; printf -v body "$GATE" $'    if: always()\n    needs: [scope, audit]\n'; workflow "$d" audit.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the gate of the audit with its whole form is accepted" "0" "$rc"
d="$(new)"; sound "$d"; printf -v body "$GATE" $'    needs: [scope, audit]\n'; workflow "$d" audit.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the gate of the audit without its if: always() is refused" "1" "$rc"
check "and it is refused for the missing form, naming the job" "1" \
	"$(said "$out" 'job `gate` in .github/workflows/audit.yml lacks the whole form')"
d="$(new)"; sound "$d"; printf -v body "$GATE" $'    if: always()\n'; workflow "$d" audit.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the gate of the audit without its needs: is refused" "1" "$rc"
check "and it is refused for the missing form, naming the job" "1" \
	"$(said "$out" 'job `gate` in .github/workflows/audit.yml lacks the whole form')"
d="$(new)"; sound "$d"; printf -v body "$GATE" $'    if: always()\n    needs: [scope]\n'; workflow "$d" audit.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the gate of the audit that waits for one job less is refused" "1" "$rc"
d="$(new)"; sound "$d"; printf -v body "$GATE" $'    if: success()\n    needs: [scope, audit]\n'; workflow "$d" audit.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the gate of the audit with another condition is refused" "1" "$rc"
check "and it is refused for the if:, naming the job" "1" \
	"$(said "$out" 'job `gate` in .github/workflows/audit.yml carries a job-level `if:`')"

# The suite and the gate of a repository that waits for the cheap checks first: `needs:` on
# jobs that GitHub never skips is not a switch, and the gate keeps its whole form.
CHEAP='dco, empty-diff, commit-identity, secret-scan, folder-limit, line-limit, workflow-lint'
WAIT=$'name: Tests\non: pull_request\njobs:\n  shell:\n    needs: [%s]\n    uses: ./.github/workflows/reusable-shell-ci.yml\n    with:\n      test-command: ./tests/ci/suites/check-suite-completeness.test.sh ./tests/a.test.sh\n  gate:\n    name: audit gate\n%s    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
d="$(new)"; sound "$d"; cp "$HERE/.github/workflows/reusable-shell-ci.yml" "$d/.github/workflows/"
printf -v body "$WAIT" "$CHEAP" $'    if: always()\n    needs: ['"$CHEAP, shell"$']\n'; workflow "$d" tests.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the suite that waits for the cheap checks, and its gate, are accepted" "0" "$rc"
printf -v body "$WAIT" "$CHEAP, folder-limit" $'    if: always()\n    needs: ['"$CHEAP, shell"$']\n'; workflow "$d" tests.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the suite that waits for one more job is refused" "1" "$rc"
printf -v body "$WAIT" "$CHEAP" $'    needs: ['"$CHEAP, shell"$']\n'; workflow "$d" tests.yml "$body"
out="$(run_in "$d")"; rc=$?
check "the gate of the suite without its if: always() is refused" "1" "$rc"
check "and it is refused for the missing form, naming the job" "1" \
	"$(said "$out" 'job `gate` in .github/workflows/tests.yml lacks the whole form')"

finish
