#!/usr/bin/env bash
# The forms the rule accepts (scripts/quality/lint/switch-rule-forms.py) are read
# from the base commit of a pull request, so a pull request cannot widen what it
# is judged by, and are read from the working tree, then from beside the rule,
# when there is no base or the base does not hold them yet.
#
# Every refusal asserts which refusal, and is paired with the acceptance of the
# same tree under the forms that list it.
#
# Requires: python3 with PyYAML.
# The fixtures are printf templates and carry backticks the assertions read.
# shellcheck disable=SC2016,SC2059
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091 # the fixture of the suites of this rule
. "$HERE/tests/fixtures/ci/switchable-rule.sh"

FORMS="$HERE/scripts/quality/lint/switch-rule-forms.py"
EXTRA=$'name: Extra\non: pull_request\njobs:\n  later:\n    if: github.event_name == \'push\'\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
widen() { # <dir>: a copy of the forms that lists the job of EXTRA
	mkdir -p "$1/scripts/quality/lint"
	cp "$FORMS" "$1/scripts/quality/lint/switch-rule-forms.py"
	printf '\nCONDITIONAL_JOBS[(_W + "extra.yml", "later", None)] = {"if": "github.event_name == '"'"'push'"'"'"}\n' >> "$1/scripts/quality/lint/switch-rule-forms.py"
}

# The tree lists the job in its own copy of the forms and the base does not: the base decides.
base_repo
mkdir -p "$G/scripts/quality/lint"; cp "$FORMS" "$G/scripts/quality/lint/"
gitg add -A; gitg commit -qm "base with the forms"; BASE="$(gitg rev-parse HEAD)"
printf '%s' "$EXTRA" > "$G/.github/workflows/extra.yml"; widen "$G"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a pull request that lists its own conditional job in the forms is judged by the forms of the base" "1" "$rc"
check "and the job is refused for its condition" "1" "$(said "$out" 'job `later` in .github/workflows/extra.yml carries a job-level `if:`')"

# The base has no forms yet: the first pull request that adds them is judged by its own.
base_repo; BASE="$(gitg rev-parse HEAD)"
printf '%s' "$EXTRA" > "$G/.github/workflows/extra.yml"; widen "$G"
out="$(run_base "$G" "$BASE")"; rc=$?
check "a base that holds no forms leaves the working tree's copy to decide" "0" "$rc"
rm -f "$G/scripts/quality/lint/switch-rule-forms.py"
out="$(run_base "$G" "$BASE")"; rc=$?
check "and with no copy in the tree the copy beside the rule has no such job, so the job is refused" "1" "$rc"

# No forms anywhere: the rule says so and fails, instead of accepting everything.
mkdir -p "$WORK/alone"; cp "$SCRIPT" "$WORK/alone/rule.sh"
base_repo
out="$(cd "$G" && env -u BASE_SHA bash "$WORK/alone/rule.sh" 2>&1)"; rc=$?
check "a rule with no forms to read fails" "1" "$rc"
check "and says that the forms cannot be read" "1" "$(said "$out" 'switch-rule-forms.py cannot be read')"

# The unreadable base is not a licence either: a named base without the file falls back to the tree.
out="$(cd "$G" && BASE_SHA=0000000000000000000000000000000000000000 bash "$WORK/alone/rule.sh" 2>&1)"; rc=$?
check "a base that cannot be read does not make the rule accept a tree without forms" "1" "$rc"

finish
