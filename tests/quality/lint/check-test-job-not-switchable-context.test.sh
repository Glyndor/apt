#!/usr/bin/env bash
# The context of a producer, not only the producer: the steps before it and
# the settings of the job and of the workflow around it.
#
# A step before the producer can write to $GITHUB_ENV or $GITHUB_PATH, and an
# `env:` or `defaults:` of the job or of the workflow changes what the
# producer's run sees, so the producer is held with everything it can see: the
# steps up to it, whole, and the settings of the job and of the workflow around
# them. A change in a step after the producer does not matter to it.
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

# --- the context of the producer, not only the producer ----------------------
#
# A step before the producer can write to $GITHUB_ENV or $GITHUB_PATH, and an
# `env:` of the job or of the workflow changes what the producer's run sees, so
# the producer is held with everything it can see: the steps up to it, whole,
# and the settings of the job and of the workflow around them.
SEE='the refusal names the file, the job and the step'
base_repo
change "$SHELL_CI" "doc['jobs']['test']['steps'].insert(0, {'run': 'echo needed=false >> \"\$GITHUB_ENV\"'})"
verdict "a step added before the scope step that writes to GITHUB_ENV is refused" 1
check "and $SEE" "1" \
	"$(said "$out" 'step `scope` of job `test` in .github/workflows/reusable-shell-ci.yml writes outputs a condition reads')"
check "and it says what differs, the first step" "1" "$(said "$out" "commit's in: step 1")"
check "and that the change goes in two pull requests" "1" "$(said "$out" 'PRODUCERS_MAY_CHANGE of this script in a pull request of its own')"

base_repo
change "$SHELL_CI" "doc['jobs']['test']['env'] = {'X': '1'}"
verdict "a new env: on the job of the scope step is refused" 1
check "and it names the env of the job" "1" "$(said "$out" "commit's in: env of the job")"
base_repo
change "$SHELL_CI" "doc['env'] = {'X': '1'}"
verdict "a new env: on the workflow is refused" 1
check "and it names the env of the workflow" "1" "$(said "$out" 'env of the workflow')"
base_repo
change "$SHELL_CI" "doc['jobs']['test']['defaults'] = {'run': {'shell': 'sh'}}"
verdict "new defaults: on the job of the scope step are refused" 1
check "and it names the defaults of the job" "1" "$(said "$out" 'defaults of the job')"
base_repo
change "$SHELL_CI" "doc['jobs']['test']['runs-on'] = 'ubuntu-latest'"
verdict "another runs-on: on the job of the scope step is refused" 1
check "and it names the runs-on of the job" "1" "$(said "$out" 'runs-on of the job')"
base_repo
change "$SHELL_CI" "s = $SCOPE_STEP; s['new-key'] = 'x'"
verdict "a key the scope step did not have is refused" 1
check "and it names the step" "1" "$(said "$out" 'step `scope` of job `test`')"

base_repo
change "$SHELL_CI" "doc['jobs']['test']['steps'].append({'run': 'true'}); doc['jobs']['test']['steps'][-2]['name'] = 'Run the tests again'"
verdict "a step after the scope step, and a renamed one, are accepted" 0
base_repo
change "$SHELL_CI" "s = $SCOPE_STEP; s['name'] = 'Decide in another way'"
verdict "a scope step with another name is accepted" 0
base_repo
change "$SHELL_CI" "del doc['jobs']['test']['defaults']"
verdict "a setting of the job that the pull request takes away is refused" 1
check "and it names the defaults of the job" "1" "$(said "$out" 'defaults of the job')"

for key in container services permissions; do
	base_repo
	change "$SHELL_CI" "doc['jobs']['test']['$key'] = {'x': 'y'}"
	verdict "a new $key: on the job of the scope step is refused" 1
	check "and it names the $key of the job" "1" "$(said "$out" "$key of the job")"
done
base_repo
change "$SHELL_CI" "doc['defaults'] = {'run': {'shell': 'sh'}}"
verdict "new defaults: on the workflow are refused" 1
check "and it names the defaults of the workflow" "1" "$(said "$out" 'defaults of the workflow')"


finish
