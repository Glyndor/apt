#!/usr/bin/env bash
# The forms the rule accepts (scripts/quality/lint/switch-rule-forms.json) are data,
# read from the base commit of a pull request and from nowhere else when one is
# named, so a pull request cannot widen what it is judged by. They are read from
# the working tree, then from beside the rule, only when no base is named.
#
# The aggregators listed in the forms (the gate that answers for a job that waits
# for others) are tied to the base commit's copy like a producer, whether or not
# the job that waits still has `needs:`.
#
# Every refusal asserts which refusal, and is paired with the acceptance of the
# same tree under the forms or the gate that allow it.
#
# Requires: python3 with PyYAML.
# The fixtures are printf templates and carry backticks the assertions read.
# shellcheck disable=SC2016,SC2059
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091 # the fixture of the suites of this rule
. "$HERE/tests/fixtures/ci/switchable-rule.sh"

FORMS="$HERE/scripts/quality/lint/switch-rule-forms.json"
EXTRA=$'name: Extra\non: pull_request\njobs:\n  later:\n    if: github.event_name == \'push\'\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
forms_with() { # <dir> <python statement on d>: a copy of the forms, changed
	mkdir -p "$1/scripts/quality/lint"
	python3 -I - "$FORMS" "$1/scripts/quality/lint/switch-rule-forms.json" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PY
}
LIST_LATER="d['conditional_jobs'].append({'file': '.github/workflows/extra.yml', 'job': 'later', 'reusable': None, 'forms': [{'if': \"github.event_name == 'push'\"}], 'why': 'x'})"

# --- where the forms come from --------------------------------------------------
base_repo
forms_with "$G" "pass"; gitg add -A; gitg commit -qm "base with the forms"; BASE="$(gitg rev-parse HEAD)"
printf '%s' "$EXTRA" > "$G/.github/workflows/extra.yml"; forms_with "$G" "$LIST_LATER"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a pull request that lists its own conditional job in the forms is judged by the forms of the base" "1" "$rc"
check "and the job is refused for its condition" "1" "$(said "$out" 'job `later` in .github/workflows/extra.yml carries a job-level `if:`')"

base_repo; gitg rm -q -r scripts; gitg commit -qm "no forms"; BASE="$(gitg rev-parse HEAD)"
printf '%s' "$EXTRA" > "$G/.github/workflows/extra.yml"; forms_with "$G" "$LIST_LATER"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a base named that holds no forms is an error, not a fall back to the copy of the pull request" "1" "$rc"
check "and the error says the forms cannot be read from the base commit" "1" "$(said "$out" 'cannot be read')"

base_repo
forms_with "$G" "pass"; printf '{"conditional_jobs": 3}' > "$G/scripts/quality/lint/switch-rule-forms.json"; gitg add -A; gitg commit -qm "forms that are not data"; BASE="$(gitg rev-parse HEAD)"
out="$(run_base "$G" "$BASE")"; rc=$?
check "forms in the base that are not the data the rule reads are an error" "1" "$rc"
check "and the error says so" "1" "$(said "$out" 'is not the data the rule reads')"
printf 'not json at all' > "$G/scripts/quality/lint/switch-rule-forms.json"; gitg add -A; gitg commit -qm "forms that are not json"; BASE="$(gitg rev-parse HEAD)"
out="$(run_base "$G" "$BASE")"; rc=$?
check "forms in the base that do not parse are an error" "1" "$rc"
check "and the error says so" "1" "$(said "$out" 'is not the data the rule reads')"
printf 'import os; os.system("true")' > "$G/scripts/quality/lint/switch-rule-forms.json"; gitg add -A; gitg commit -qm "forms that are code"; BASE="$(gitg rev-parse HEAD)"
out="$(run_base "$G" "$BASE")"; rc=$?
check "forms that are code, not data, are an error and are never run" "1" "$rc"

out="$(cd "$G" && BASE_SHA=not-a-commit bash "$SCRIPT" 2>&1)"; rc=$?
check "a base that is not a commit id is an error" "1" "$rc"
check "and the error says so" "1" "$(said "$out" 'is not a commit id')"

mkdir -p "$WORK/alone"; cp "$SCRIPT" "$WORK/alone/rule.sh"; base_repo; rm -rf "$G/scripts"
out="$(cd "$G" && env -u BASE_SHA bash "$WORK/alone/rule.sh" 2>&1)"; rc=$?
check "with no base and no forms anywhere the rule fails" "1" "$rc"
check "and says the forms cannot be read" "1" "$(said "$out" 'switch-rule-forms.json cannot be read')"
forms_with "$G" "pass"; printf '%s' "$EXTRA" > "$G/.github/workflows/extra.yml"
out="$(cd "$G" && env -u BASE_SHA bash "$WORK/alone/rule.sh" 2>&1)"; rc=$?
check "with no base the copy in the working tree is read" "1" "$rc"
check "and it refuses the job it does not list" "1" "$(said "$out" 'job `later` in .github/workflows/extra.yml carries a job-level `if:`')"
forms_with "$G" "$LIST_LATER"
out="$(cd "$G" && env -u BASE_SHA bash "$WORK/alone/rule.sh" 2>&1)"; rc=$?
check "and accepts it once the working tree's copy lists it" "0" "$rc"

# --- the aggregator that answers for the job that waits -------------------------
CHEAP='dco, empty-diff, commit-identity, secret-scan, folder-limit, line-limit, workflow-lint'
WAIT=$'name: Tests\non: pull_request\n%s\njobs:\n  shell:\n    needs: [%s]\n    uses: ./.github/workflows/reusable-shell-ci.yml\n    with:\n      test-command: ./tests/ci/suites/check-suite-completeness.test.sh ./tests/a.test.sh\n%s'
GATE_OK=$'  gate:\n    if: always()\n    needs: ['"$CHEAP, shell"$']\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo %s\n'
waiting() { # <env block or -> <gate text or -> <dir>: tests.yml with the suite that waits
	local d="${3:-$WORK/t}" env="$1"
	[ -n "${3:-}" ] || new > /dev/null
	mkdir -p "$d/.github/workflows"; cp "$HERE/.github/workflows/reusable-shell-ci.yml" "$d/.github/workflows/"
	[ "$env" != - ] || env='env: {}'
	if [ "$2" = - ]; then printf -v body "$WAIT" "$env" "$CHEAP" ''; else printf -v body "$WAIT" "$env" "$CHEAP" "$2"; fi
	printf '%s\n' "$body" > "$d/.github/workflows/tests.yml"
}
printf -v g "$GATE_OK" verdict
waiting - "$g"; out="$(run_in "$WORK/t")"; rc=$?
check "the suite that waits for the cheap checks is accepted beside its gate" "0" "$rc"
waiting - -; out="$(run_in "$WORK/t")"; rc=$?
check "the same suite with no gate in the file is refused" "1" "$rc"
check "and the refusal says no gate answers for it" "1" "$(said "$out" 'waits for other jobs and no `gate` job answers for it')"
waiting - "${g/    if: always()/    if: success()}"; out="$(run_in "$WORK/t")"; rc=$?
check "a gate that does not run whatever happened does not count" "1" "$rc"
check "and the suite is refused for it, not only the gate" "1" "$(said "$out" 'job `shell` in .github/workflows/tests.yml waits for other jobs')"
waiting - "${g/    runs-on/    continue-on-error: true
    runs-on}"; out="$(run_in "$WORK/t")"; rc=$?
check "a gate that may fail without failing the run does not count" "1" "$rc"
check "and the suite is refused for it" "1" "$(said "$out" 'job `shell` in .github/workflows/tests.yml waits for other jobs')"
waiting - "${g/, shell]/]}"; out="$(run_in "$WORK/t")"; rc=$?
check "a gate that does not wait for the suite itself does not count" "1" "$rc"
check "and the suite is refused for it" "1" "$(said "$out" 'job `shell` in .github/workflows/tests.yml waits for other jobs')"
waiting - "${g/dco, /}"; out="$(run_in "$WORK/t")"; rc=$?
check "a gate that leaves out one of the checks the suite waits for does not count" "1" "$rc"
check "and the suite is refused for it" "1" "$(said "$out" 'job `shell` in .github/workflows/tests.yml waits for other jobs')"

# The gate is the base commit's. A base holds the workflow with its gate, and the forms list it.
aggregator_repo() { # <gate text for the base> : $G with tests.yml in the base commit
	base_repo; rm -f "$G/.github/workflows/mutation.yml"; waiting - "$1" "$G"
	forms_with "$G" "pass"; gitg add -A; gitg commit -qm "base with a gate"; BASE="$(gitg rev-parse HEAD)"
}
printf -v g2 "$GATE_OK" "true"
aggregator_repo "$g"; out="$(run_base "$G" "$BASE")"; rc=$?
check "a gate that is the base commit's is accepted" "0" "$rc"
waiting - "$g2" "$G"; out="$(run_base "$G" "$BASE")"; rc=$?
check "a gate whose step was rewritten in the pull request is refused" "1" "$rc"
check "and the refusal says what differs from the base commit's" "1" "$(said "$out" '`gate` in .github/workflows/tests.yml answers for `shell`, and what it can see differs from the base commit')"
# Taking the `needs:` off the job that waits does not release the gate.
printf '%s\n' "$(cat "$G/.github/workflows/tests.yml")" | sed '/^    needs: \[dco/d' > "$WORK/free.yml"; cp "$WORK/free.yml" "$G/.github/workflows/tests.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a gate rewritten while the job that waits has lost its needs: is still refused" "1" "$rc"
check "and it is refused for the gate, not for the job" "1" "$(said "$out" 'what it can see differs from the base commit')"
# What the gate can see: the env of the workflow, a script of the checkout.
waiting 'env: {X: "1"}' "$g" "$G"; out="$(run_base "$G" "$BASE")"; rc=$?
check "a change to the env of the workflow the gate runs in is refused" "1" "$rc"
check "and the refusal names the env of the workflow" "1" "$(said "$out" 'env of the workflow')"
printf -v g3 "$GATE_OK" "x"; g3="${g3/echo x/bash .\/scripts\/gate.sh}"
waiting - "$g3" "$G"; out="$(run_base "$G" "$BASE")"; rc=$?
check "a gate that runs a script from the checkout of the pull request is refused" "1" "$rc"
check "and the refusal says the pull request writes it" "1" "$(said "$out" 'runs a script of the repository from the checkout of the pull request')"
# A gate the base does not hold.
base_repo; rm -f "$G/.github/workflows/mutation.yml"; waiting - - "$G"; gitg add -A; gitg commit -qm "base without a gate"; BASE="$(gitg rev-parse HEAD)"
forms_with "$G" "pass"; gitg add -A; gitg commit -qm "forms"; BASE="$(gitg rev-parse HEAD)"
waiting - "$g" "$G"; out="$(run_base "$G" "$BASE")"; rc=$?
check "a gate that the pull request brings and the base does not hold is refused" "1" "$rc"
check "and the refusal says the base cannot vouch for it" "1" "$(said "$out" 'is new in this pull request, so the base commit cannot vouch for it')"
cp "$G/.github/workflows/tests.yml" "$WORK/pr-tests.yml"; git -C "$G" checkout -q -- .github/workflows/tests.yml
forms_with "$G" "d['producers_may_change'].append(['.github/workflows/tests.yml', 'gate'])"; gitg add -A; gitg commit -qm "forms list the gate"; BASE="$(gitg rev-parse HEAD)"
cp "$WORK/pr-tests.yml" "$G/.github/workflows/tests.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "and is accepted once the forms of the base list it for adoption" "0" "$rc"

# Taking the aggregator away, or letting another job stand for it.
aggregator_repo "$g"
printf -v body "$WAIT" 'env: {}' "$CHEAP" ''; printf '%s\n' "$body" | sed 's/^    needs: \[.*\]$//' > "$G/.github/workflows/tests.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a pull request that deletes the gate the base holds, and the needs: of the job it answered for, is refused" "1" "$rc"
check "and the refusal says the gate is gone from the pull request" "1" "$(said "$out" '`gate` of .github/workflows/tests.yml answers for `shell` in the base commit and is gone from this pull request')"
aggregator_repo "$g"; rm "$G/.github/workflows/tests.yml"; printf 'name: Other\non: pull_request\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$G/.github/workflows/other.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a pull request that deletes the whole file of the gate is refused as well" "1" "$rc"
check "and the refusal is the same" "1" "$(said "$out" 'is gone from this pull request')"
aggregator_repo "$g"
forms_with "$G" "d['producers_may_change'].append(['.github/workflows/tests.yml', 'gate'])"; gitg add -A; gitg commit -qm "forms list the gate"; BASE="$(gitg rev-parse HEAD)"
rm -f "$G/.github/workflows/tests.yml"; printf 'name: Other\non: pull_request\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$G/.github/workflows/other.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "and the gate may go in a pull request of its own that the forms of the base listed" "0" "$(said "$out" 'is gone from this pull request')"
aggregator_repo "$g"; printf -v body "$WAIT" 'env: {}' "$CHEAP" "$g"; printf '%s\n' "$body" > "$G/.github/workflows/tests.yml"
printf 'name: Other\non: pull_request\njobs:\n  later:\n    name: gate\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$G/.github/workflows/other.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a job of another workflow named like the check of the gate is refused" "1" "$rc"
check "and the refusal says another job cannot stand for it" "1" "$(said "$out" 'job `later` in .github/workflows/other.yml is named `gate`')"

# What counts as the same name: the effective one, trimmed and without case, and no expression that could resolve to it.
other() { # <job fragment>: another workflow next to the aggregator's
	aggregator_repo "$g"; printf -v body "$WAIT" 'env: {}' "$CHEAP" "$g"; printf '%s\n' "$body" > "$G/.github/workflows/tests.yml"
	printf 'name: Other\non: pull_request\njobs:\n%s    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' "$1" > "$G/.github/workflows/other.yml"
	out="$(run_base "$G" "$BASE")"; rc=$?
}
other $'  later:\n    name: " gate "\n'
check "a job named with spaces around the check name is the same name and is refused" "1" "$rc"
check "and the refusal says another job cannot stand for it" "1" "$(said "$out" 'job `later` in .github/workflows/other.yml is named `gate`')"
other $'  later:\n    name: Gate\n'
check "a job named with another case is the same name and is refused" "1" "$rc"
other $'  gate:\n    name: ""\n'
check "a job with an empty name and the id of the aggregator is named like it and is refused" "1" "$rc"
check "and the refusal names the job" "1" "$(said "$out" 'job `gate` in .github/workflows/other.yml is named `gate`')"
other $'  later:\n    name: gate-${{ github.event_name }}\n'
check "a job named with an expression that nothing lists is refused" "1" "$rc"
check "and the refusal says the expression can resolve to the check name" "1" "$(said "$out" 'has a name with an expression')"
other $'  later:\n    name: another name\n'
check "control: a job with another name is accepted next to the gate" "0" "$rc"
EXPR='gate-${{ github.event_name }}'
LISTED="d['expression_names'].append({'file': '.github/workflows/other.yml', 'job': 'later', 'name': '$EXPR'})"
expr_workflow() { printf 'name: Other\non: pull_request\njobs:\n  later:\n    name: %s\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' "$1" > "$G/.github/workflows/other.yml"; }
aggregator_repo "$g"; expr_workflow "$EXPR"; forms_with "$G" "$LISTED"; gitg add -A; gitg commit -qm "base with the name"; BASE="$(gitg rev-parse HEAD)"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a name with an expression that the forms of the base list, and the base's job already has, is accepted" "0" "$rc"
expr_workflow 'gate-${{ github.actor }}'
out="$(run_base "$G" "$BASE")"; rc=$?
check "the same job with another expression is refused: the name is compared literally" "1" "$rc"
aggregator_repo "$g"; forms_with "$G" "$LISTED"; expr_workflow 'gate-${{ github.actor }}'; gitg add -A; gitg commit -qm "base holds another expression"; BASE="$(gitg rev-parse HEAD)"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a listed job that keeps an expression other than the listed one is refused even when the base has it" "1" "$rc"
aggregator_repo "$g"; forms_with "$G" "$LISTED"; gitg add -A; gitg commit -qm "forms list the name"; BASE="$(gitg rev-parse HEAD)"
expr_workflow "$EXPR"; out="$(run_base "$G" "$BASE")"; rc=$?
check "a listed name on a job the base does not have is refused" "1" "$rc"
check "and the refusal says the base commit's job has to hold it already" "1" "$(said "$out" 'Only the exact name the forms list for it, and the base commit')"
aggregator_repo "$g"; printf -v body "$WAIT" 'env: {}' "$CHEAP" "$g"; printf '%s\n' "$body" > "$G/.github/workflows/tests.yml"
printf 'name: Broken\non: pull_request\njobs: [\n' > "$G/.github/workflows/other.yml"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a workflow that cannot be read is an error" "1" "$rc"
check "and the refusal names the file" "1" "$(said "$out" 'other.yml cannot be read as YAML')"

# Every listed form that carries `if: always()` is an aggregator, so the others are tied to the base as well.
audit_gate() { printf 'name: Audit\non: pull_request\njobs:\n  scope:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  audit:\n    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.run_audit != '"'"'false'"'"' }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  gate:\n    name: audit gate\n    needs: [scope, audit]\n    if: always()\n    runs-on: ubuntu-latest\n    steps:\n      - run: %s\n' "$1" > "$G/.github/workflows/audit.yml"; }
base_repo; rm -f "$G/.github/workflows/mutation.yml"; audit_gate verdict; gitg add -A; gitg commit -qm "base with the audit gate"; BASE="$(gitg rev-parse HEAD)"
out="$(run_base "$G" "$BASE")"; rc=$?
check "the audit gate the base holds is accepted" "0" "$rc"
audit_gate true; out="$(run_base "$G" "$BASE")"; rc=$?
check "an audit gate whose step was rewritten is refused, without any job waiting on it in the forms" "1" "$rc"
check "and the refusal says what differs from the base commit's" "1" "$(said "$out" '`gate` in .github/workflows/audit.yml answers for')"
rm "$G/.github/workflows/audit.yml"; out="$(run_base "$G" "$BASE")"; rc=$?
check "an audit gate taken away with its file is refused" "1" "$rc"
check "and the refusal says it is gone from the pull request" "1" "$(said "$out" '`gate` of .github/workflows/audit.yml')"

# The conditions the forms list for jobs a repository may not have yet are not refused as unlisted where they
# stand. The expectation is written here, not read from the forms, so a forms file that lost one fails.
plant() { # <file> <job> <condition>
	base_repo
	[ -f "$G/.github/workflows/$1" ] || printf 'name: Planted\non: pull_request\njobs: {}\n' > "$G/.github/workflows/$1"
	change "$1" "doc['jobs'].setdefault('$2', {'runs-on': 'ubuntu-latest', 'steps': [{'run': 'true'}]})['steps'][0]['if'] = \"$3\""
	out="$(run_base "$G" "$BASE")"
	check "the step condition listed for $2 in $1 is not refused as unlisted" "0" "$(said "$out" 'does not list for the job')"
}
plant tests.yml formulae "steps.scope.outputs.run_style != 'false'"
plant tests.yml products "github.event_name == 'pull_request'"
plant update.yml validate "needs.render.outputs.changed == '1'"
plant drift.yml drift '${{ !cancelled() }}'
plant update.yml render "steps.render.outputs.changed == '1'"
plant update.yml commit "needs.render.outputs.partial == '1'"

# The job-level forms the forms list for a workflow a repository may not have yet are accepted where they stand.
base_repo
printf 'name: Planted\non: workflow_dispatch\njobs:\n  render:\n    runs-on: x\n    steps: [{run: "true"}]\n  validate:\n    needs: render\n    runs-on: x\n    steps: [{run: "true"}]\n  commit:\n    needs: [render, validate]\n    runs-on: x\n    steps: [{run: "true"}]\n' > "$G/.github/workflows/update.yml"
out="$(run_base "$G" "$BASE")"
check "the needs the forms list for the jobs of update.yml are not refused" "0" "$(said "$out" 'carries `needs:`')"

finish
