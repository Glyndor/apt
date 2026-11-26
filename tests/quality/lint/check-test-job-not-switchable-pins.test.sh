#!/usr/bin/env bash
# What a condition reads is held to the base commit: the producer of an
# output, as the base commit has it.
#
# A form the lists accept (`steps.scope.outputs.needed != 'false'`) is only as
# sound as the step that writes the output. A pull request that makes that step
# write `false` skips the check through an accepted form, so the step, or the job
# for `needs.<job>.outputs`, is held to the base commit: what it runs, passes and
# writes may not differ from there. A step's name and the pin of an action do not
# count, a base that cannot be read stops the rule, and with no base named
# nothing is compared.
#
# Every refusal asserts which refusal, and every refusal is paired with the
# acceptance of the same tree before the switch was planted.
#
# Requires: python3 with PyYAML.
# The fixtures are printf templates and carry backticks the assertions read.
# shellcheck disable=SC2016,SC2059
# BASE is read by the helpers of the fixture, not by this file.
# shellcheck disable=SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091 # the fixture of the suites of this rule
. "$HERE/tests/fixtures/ci/switchable-rule.sh"

base_repo
verdict "the producers as the base has them are accepted" 0
change "$SHELL_CI" "doc['jobs']['test']['name'] = 'renamed'"
verdict "a pull request that rewrites the file without changing a producer is accepted" 0

change "$SHELL_CI" "s = $SCOPE_STEP; s['run'] += chr(10) + 'echo docs_only=true >> \"\$GITHUB_OUTPUT\"'"
verdict "the scope step that always writes docs_only=true is refused" 1
check "and the refusal names the file, the job and the step" "1" \
	"$(said "$out" 'step `scope` of job `test` in .github/workflows/reusable-shell-ci.yml writes outputs a condition reads')"
check "and says how to change a producer on purpose" "1" "$(said "$out" 'in PRODUCERS_MAY_CHANGE of the forms')"
out="$(cd "$G" && env -u BASE_SHA bash "$SCRIPT" 2>&1)"; rc=$?
check "the same change with no base commit named is not compared" "0" "$rc"

# The same change when the forms of the base commit list the step: the two-step way.
cp "$G/.github/workflows/reusable-shell-ci.yml" "$WORK/changed.yml"; git -C "$G" checkout -q -- .github/workflows/reusable-shell-ci.yml
BASE0="$(gitg rev-parse HEAD)"
cp "$WORK/changed.yml" "$G/.github/workflows/reusable-shell-ci.yml"
out="$(run_base "$G" "$BASE0")"
DIGEST="$(printf '%s' "$out" | sed -n 's/.*digest `\([0-9a-f]\{64\}\)`.*/\1/p' | head -n 1)"
check "the refusal of the change names the digest of what it makes of the step" "1" "$(printf '%s' "$DIGEST" | grep -cE '^[0-9a-f]{64}$')"
git -C "$G" checkout -q -- .github/workflows/reusable-shell-ci.yml
listed() { # <digest> : the forms of the base list the step, with this digest
	python3 -I - "$G/scripts/quality/lint/switch-rule-forms.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["producers_may_change"] = [{"file": ".github/workflows/reusable-shell-ci.yml", "ident": "scope", "digest": sys.argv[2]}]
json.dump(d, open(sys.argv[1], "w"))
PY
	gitg add -A; gitg commit -qm "forms list the step"; gitg rev-parse HEAD
}
unlist() { # the pull request takes its exemption off its own copy of the forms
	python3 -I - "$G/scripts/quality/lint/switch-rule-forms.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["producers_may_change"] = []
json.dump(d, open(sys.argv[1], "w"))
PY
}
LISTED="$(listed "$DIGEST")"
cp "$WORK/changed.yml" "$G/.github/workflows/reusable-shell-ci.yml"; unlist
out="$(run_base "$G" "$LISTED")"; rc=$?
check "the change is accepted once a pull request of its own has listed the step with the digest of the change" "0" "$rc"
check "and the exemption that names the content is not read as surplus in the pull request that makes the change when it is the base's" "0" "$(said "$out" 'has done its work')"
git -C "$G" checkout -q -- .github/workflows/reusable-shell-ci.yml
OTHER="$(listed 0000000000000000000000000000000000000000000000000000000000000000)"
cp "$WORK/changed.yml" "$G/.github/workflows/reusable-shell-ci.yml"
out="$(run_base "$G" "$OTHER")"; rc=$?
check "a step changed under an exemption that names other content is refused" "1" "$rc"
check "and the refusal says what it differs in and names the digest to list" "1" "$(said "$out" "$DIGEST")"
git -C "$G" checkout -q -- .github/workflows/reusable-shell-ci.yml
# The copy of the pull request still lists an exemption whose content the producer already is.
BASE1="$(gitg rev-parse HEAD)"
cp "$WORK/changed.yml" "$G/.github/workflows/reusable-shell-ci.yml"
python3 -I - "$G/scripts/quality/lint/switch-rule-forms.json" "$DIGEST" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["producers_may_change"] = [{"file": ".github/workflows/reusable-shell-ci.yml", "ident": "scope", "digest": sys.argv[2]}]
json.dump(d, open(sys.argv[1], "w"))
PY
out="$(run_base "$G" "$LISTED")"; rc=$?
check "an exemption that the pull request's own forms still list, once the producer is what it names, is refused as surplus" "1" "$rc"
check "and the refusal says it has done its work" "1" "$(said "$out" 'has done its work')"
git -C "$G" checkout -q -- . ; git -C "$G" reset -q --hard "$BASE1"

base_repo
change "$SHELL_CI" "s = $SCOPE_STEP; s['env']['SKIP_PATHS'] = 'docs/**'"
verdict "the scope step with another env is refused" 1
check "and it is refused as a producer that differs" "1" "$(said "$out" 'differs from the base commit')"

base_repo
change "$SHELL_CI" "s = $SCOPE_STEP; del s['id']"
verdict "a step that stopped writing the output a condition reads is refused" 1
check "and the refusal says nothing writes it, naming the job" "1" \
	"$(said "$out" 'job `test` in .github/workflows/reusable-shell-ci.yml reads `steps.scope.outputs`, which nothing in the file writes')"

base_repo
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'echo \"suite=false\" >> \"\$GITHUB_OUTPUT\"'"
verdict "the scope job that writes suite=false is refused" 1
check "and the refusal names the file and the job" "1" \
	"$(said "$out" 'job `scope` in .github/workflows/freshness.yml writes outputs a condition reads')"

base_repo
change freshness.yml "doc['jobs']['scope']['outputs']['suite'] = 'false'"
verdict "the scope job whose output is a constant is refused" 1
check "and the refusal names the job" "1" "$(said "$out" 'job `scope` in .github/workflows/freshness.yml')"

base_repo
change freshness.yml "doc['jobs']['scope']['steps'][0]['uses'] = 'actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
verdict "a bump of the pin of an action in the producer is accepted" 0

base_repo
change freshness.yml "doc['jobs']['scope']['steps'][0]['with'] = {'fetch-depth': 0}"
verdict "an argument of an action in the producer changed is refused" 1

base_repo
rm "$G/.github/workflows/freshness.yml"; gitg add -A; gitg commit -qm 'without it'; BASE="$(gitg rev-parse HEAD)"
printf '%s' "$SCOPE_FILE" > "$G/.github/workflows/freshness.yml"
verdict "a producer and its reader that both arrive in the pull request are refused" 1
check "and the refusal says the base cannot vouch for it" "1" "$(said "$out" 'is new in this pull request')"

base_repo
printf 'jobs: [\n' > "$G/.github/workflows/freshness.yml"; gitg add -A; gitg commit -qm 'broken'; BASE="$(gitg rev-parse HEAD)"
printf '%s' "$SCOPE_FILE" > "$G/.github/workflows/freshness.yml"
verdict "a producer whose file the base commit cannot parse is refused" 1
check "and the refusal says the base cannot vouch for it" "1" "$(said "$out" 'is new in this pull request')"

base_repo
change freshness.yml "del doc['jobs']['scope']"
verdict "a reader whose producer was deleted is refused" 1
check "and the refusal says nothing writes the output" "1" "$(said "$out" 'reads `needs.scope.outputs`, which nothing in the file writes')"


# The producer is a job: all of it, the workflow settings and the reusable it calls.
base_repo
change freshness.yml "doc['jobs']['scope']['env'] = {'X': '1'}"
verdict "a new env: on the job that produces what another job needs is refused" 1
check "and the refusal names the job and the env of the job" "1" \
	"$(said "$out" 'job `scope` in .github/workflows/freshness.yml writes outputs a condition reads, and what it can see differs from the base commit'"'"'s in: env of the job')"
base_repo
change freshness.yml "del doc['jobs']['scope']['outputs']"
verdict "a job that stops declaring the outputs another job reads is refused" 1
check "and it names the outputs of the job" "1" "$(said "$out" 'in: outputs of the job')"
base_repo
change freshness.yml "doc['jobs']['scope']['steps'].append({'run': 'true'})"
verdict "a step added after the one that writes the output, in a job that produces it, is refused" 1
check "and it names the step" "1" "$(said "$out" 'in: step 3')"
base_repo
change freshness.yml "doc['env'] = {'X': '1'}"
verdict "a new env: on the workflow of a producer job is refused" 1

# A producer job that calls a reusable: the reusable is part of it.
CALLS=$'name: Freshness\non: pull_request\njobs:\n  scope:\n    uses: ./.github/workflows/reusable-dco.yml\n  suite-on-main:\n    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.suite != \'false\' }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
base_repo
printf '%s' "$CALLS" > "$G/.github/workflows/freshness.yml"; gitg add -A; gitg commit -qm calls; BASE="$(gitg rev-parse HEAD)"
verdict "a producer job that calls a reusable, as the base has it, is accepted" 0
change reusable-dco.yml "doc['jobs']['dco']['steps'].append({'run': 'true'})"
verdict "the same job with its reusable changed is refused" 1
check "and the refusal names the reusable file" "1" "$(said "$out" 'the reusable file')"

out="$(run_base "$G" 0000000000000000000000000000000000000000)"; rc=$?
check "a base that is named and cannot be read stops the rule" "1" "$rc"
check "and says so" "1" "$(said "$out" 'cannot be read')"

finish
