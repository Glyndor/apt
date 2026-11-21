#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-workflow-lint.yml itself: that
# each assertion it adds on top of actionlint is wired to the script that holds
# the rule, under the condition it is meant to run under.
#
# The rules live in scripts/quality/ and their cases in tests/quality/: one
# suite per script. What those suites cannot see is the workflow: a step that
# stops calling its script, or calls it under a condition that never holds,
# leaves every case of the script green and the gate gone. So each step is read
# out of the workflow as it ships and its `run:` is executed in a temporary tree
# that carries the real scripts, once over a planted violation, which must turn
# it red for that rule, and once over a clean tree, which must leave it green.
#
# Requires: python3 with PyYAML.
# The fixtures carry literal `${{ secrets.X }}`; single quotes are the point.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/reusable-workflow-lint.yml"
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

# One field of one step of the workflow-lint job, read with a YAML parser so
# a comment that names the script does not count as calling it.
field() { # $1=step name $2=run|if
	python3 -I - "$WORKFLOW" "$1" "$2" <<'PY'
import sys
import yaml
spec = yaml.safe_load(open(sys.argv[1]))
steps = spec["jobs"]["workflow-lint"]["steps"]
step = next((s for s in steps if s.get("name") == sys.argv[2]), None)
print("MISSING" if step is None else str(step.get(sys.argv[3], "")).strip())
PY
}

default_of() { # $1=input name
	python3 -I - "$WORKFLOW" "$1" <<'PY'
import sys
import yaml
spec = yaml.safe_load(open(sys.argv[1]))
# PyYAML reads the bare key `on` as the boolean True.
print(spec[True]["workflow_call"]["inputs"][sys.argv[2]].get("default"))
PY
}

said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

# A repository shaped like a caller, built as a pull request is checked out: a
# base commit, a branch on top and a --no-ff merge of it, so HEAD^1 is the base.
# The base carries a caller that runs a suite and a job that holds no secret,
# and the real rule scripts unless it is a first adoption.
RULES=(check-test-job-not-switchable.sh check-tooling-isolation.sh)
gitt() { git -C "$WORK/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
base_repo() { # $1=with|without the rule scripts in the base
	local x
	rm -rf "$WORK/t"
	mkdir -p "$WORK/t/.github/workflows" "$WORK/t/scripts/quality"
	gitt init -q -b main
	if [ "$1" = with ]; then
		for x in "${RULES[@]}"; do cp "$HERE/scripts/quality/$x" "$WORK/t/scripts/quality/"; done
	fi
	cat > "$WORK/t/.github/workflows/tests.yml" <<'EOF'
name: Tests
on: pull_request
jobs:
  shell:
    uses: ./.github/workflows/reusable-shell-ci.yml
    with:
      test-command: >-
        ./tests/one.test.sh
EOF
	cat > "$WORK/t/.github/workflows/job.yml" <<'EOF'
name: Job
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      TOKEN: ${{ vars.PLAIN }}
    steps:
      - run: cargo install --locked cargo-cyclonedx
EOF
	gitt add -A
	gitt commit -qm base
	gitt checkout -q -b pr
}
merge_pr() {
	gitt add -A
	gitt commit -qm pr --allow-empty
	gitt checkout -q main
	gitt merge -q --no-ff pr -m merge
}
# The violation each rule exists to refuse, planted in the pull request.
violate() { # $1=rule
	case "$1" in
	check-test-job-not-switchable.sh)
		sed -i 's/^  shell:$/  shell:\n    if: false/' "$WORK/t/.github/workflows/tests.yml" ;;
	check-tooling-isolation.sh)
		sed -i 's/vars.PLAIN/secrets.DEPLOY_TOKEN/' "$WORK/t/.github/workflows/job.yml" ;;
	esac
}
refusal() { # $1=rule -> a fragment of that rule's refusal
	case "$1" in
	check-test-job-not-switchable.sh) printf '%s' 'job-level `if:`' ;;
	check-tooling-isolation.sh) printf '%s' 'installs third-party tooling while holding a secret' ;;
	esac
}
hollow() { # $1=rule: the pull request replaces the rule with one that passes
	printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/t/scripts/quality/$1"
}

PICK="$(field "Take the rule scripts from the base commit" run)"
pick() { # $1=event -> output, status in rc
	rm -rf "$WORK/rt"
	mkdir -p "$WORK/rt"
	out="$(cd "$WORK/t" && EVENT="$1" RUNNER_TEMP="$WORK/rt" bash -e -o pipefail -c "$PICK" 2>&1)"
	rc=$?
}
rule() { # $1=run line -> output, status in rc
	out="$(cd "$WORK/t" && RUNNER_TEMP="$WORK/rt" bash -e -o pipefail -c "$1" 2>&1)"
	rc=$?
}

check "the rule scripts are taken whenever the scope says workflow-lint is needed" \
	"steps.scope.outputs.needed != 'false'" "$(field "Take the rule scripts from the base commit" if)"

declare -A STEP=(
	[check-test-job-not-switchable.sh]="A required test job must not be switchable off"
	[check-tooling-isolation.sh]="A job holding a secret must not install third-party tooling"
)
declare -A CONDITION=(
	[check-test-job-not-switchable.sh]="steps.scope.outputs.needed != 'false'"
	[check-tooling-isolation.sh]='${{ inputs.tooling-isolation && steps.scope.outputs.needed != '"'false'"' }}'
)
for r in "${RULES[@]}"; do
	name="${r%.sh}"
	run="$(field "${STEP[$r]}" run)"
	check "$name: the step runs the copy the picker took, with an explicit interpreter" \
		"bash \"\$RUNNER_TEMP/lint-rules/$r\"" "$run"
	check "$name: and runs under its condition" "${CONDITION[$r]}" "$(field "${STEP[$r]}" if)"

	base_repo with; merge_pr
	pick pull_request; rule "$run"
	check "$name: a clean pull request passes through the step" "0" "$rc"

	base_repo with; violate "$r"; merge_pr
	pick pull_request; rule "$run"
	check "$name: a planted violation turns the step red" "1" "$rc"
	check "$name: and for that rule" "1" "$(said "$out" "$(refusal "$r")")"

	# The pull request hollows the rule out and breaks it in the same change.
	base_repo with; violate "$r"; hollow "$r"; merge_pr
	pick pull_request
	check "$name: on a pull request the picker says it read the base" "1" \
		"$(said "$out" "$r read from the base commit")"
	rule "$run"
	check "$name: a pull request that hollows the rule is still judged by the base's" "1" "$rc"
	check "$name: and refused for that rule" "1" "$(said "$out" "$(refusal "$r")")"
	# On a push there is no base to trust: the checkout is what landed.
	pick push; rule "$run"
	check "$name: on a push the checkout's copy decides" "0" "$rc"

	# First adoption: the base has no rule, so the checkout's copy decides.
	base_repo without
	for x in "${RULES[@]}"; do cp "$HERE/scripts/quality/$x" "$WORK/t/scripts/quality/"; done
	violate "$r"; merge_pr
	pick pull_request
	check "$name: a base without the rule falls back to the checkout" "0" "$(said "$out" "$r read from the base commit")"
	rule "$run"
	check "$name: and the checkout's rule refuses the violation" "1" "$rc"
done

base_repo without; merge_pr
pick pull_request
check "a rule in neither the base nor the checkout fails the picker" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and tooling-isolation is on unless a caller turns it off" "True" "$(default_of tooling-isolation)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
