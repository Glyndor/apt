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

# ===========================================================================
# What a condition reads is held to the base commit
# ===========================================================================
#
# A form the lists accept (`steps.scope.outputs.needed != 'false'`) is only as
# sound as the step that writes the output. A pull request that makes that step
# write `false` skips the check through an accepted form, so the step is held to
# the base commit: what it runs, passes and writes may not differ from there.

G="$WORK/g"
gitg() { git -C "$G" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
run_base() { ( cd "$1" && BASE_SHA="$2" bash "${3:-$SCRIPT}" 2>&1 ); }

# A job with a step that writes an output and a job that reads it, as
# freshness.yml has them: the lists name both.
SCOPE_FILE=$'name: Freshness\non: pull_request\njobs:\n  scope:\n    if: github.event_name == \'pull_request\'\n    runs-on: ubuntu-latest\n    outputs:\n      suite: ${{ steps.scope.outputs.suite }}\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1\n      - id: scope\n        run: echo "suite=true" >> "$GITHUB_OUTPUT"\n  suite-on-main:\n    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.suite != \'false\' }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
base_repo() { # the real callers and reusables, and the file above, as the base commit
	rm -rf "$G"; mkdir -p "$G/.github/workflows"; gitg init -q -b main
	cp "$HERE"/.github/workflows/*.yml "$G/.github/workflows/"
	printf '%s' "$SCOPE_FILE" > "$G/.github/workflows/freshness.yml"
	gitg add -A; gitg commit -qm base; BASE="$(gitg rev-parse HEAD)"
}
# The pull request changes a step or a job of a workflow the way the expression says.
# `doc` is the parsed file, `job` the named job: change it in place.
change() { # $1=file $2=python statements acting on doc
	python3 -I - "$G/.github/workflows/$1" "$2" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
exec(sys.argv[2])
yaml.safe_dump(doc, open(sys.argv[1], "w"))
PY
}
verdict() { # $1=description $2=expected status
	out="$(run_base "$G" "$BASE")"; rc=$?
	check "$1" "$2" "$rc"
}
SHELL_CI=reusable-shell-ci.yml
SCOPE_STEP='[s for s in doc["jobs"]["test"]["steps"] if s.get("id") == "scope"][0]'

base_repo
verdict "the producers as the base has them are accepted" 0
change "$SHELL_CI" "doc['jobs']['test']['name'] = 'renamed'"
verdict "a pull request that rewrites the file without changing a producer is accepted" 0

change "$SHELL_CI" "s = $SCOPE_STEP; s['run'] += chr(10) + 'echo docs_only=true >> \"\$GITHUB_OUTPUT\"'"
verdict "the scope step that always writes docs_only=true is refused" 1
check "and the refusal names the file, the job and the step" "1" \
	"$(said "$out" 'step `scope` of job `test` in .github/workflows/reusable-shell-ci.yml writes outputs a condition reads')"
check "and says how to change a producer on purpose" "1" "$(said "$out" 'PRODUCERS_MAY_CHANGE of this script')"
out="$(cd "$G" && env -u BASE_SHA bash "$SCRIPT" 2>&1)"; rc=$?
check "the same change with no base commit named is not compared" "0" "$rc"

# The same change on a copy of the rule that lists the step: the two-step way.
sed 's|^PRODUCERS_MAY_CHANGE = ()|PRODUCERS_MAY_CHANGE = ((".github/workflows/reusable-shell-ci.yml", "scope"),)|' "$SCRIPT" > "$WORK/listed.sh"
out="$(run_base "$G" "$BASE" "$WORK/listed.sh")"; rc=$?
check "the change is accepted once a pull request of its own has listed the step" "0" "$rc"

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

# --- the producer decides with code of the base commit -----------------------
nobase() { out="$(cd "$G" && env -u BASE_SHA bash "$SCRIPT" 2>&1)"; rc=$?; check "$1" "$2" "$rc"; }
base_repo
nobase "the scope step that reads its script from the base commit is accepted with no base named" 0
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'git show HEAD^1:scripts/s.sh > \"\$RUNNER_TEMP/s\"; bash \"\$RUNNER_TEMP/s\" >> \"\$GITHUB_OUTPUT\"'"
nobase "and so is one that runs what it took from the base with git show" 0
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'bash ./scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'"
nobase "a scope step that runs a script of the repository from the checkout is refused with no base named" 1
check "and the refusal says the pull request writes it, naming the job and the file" "1" \
	"$(said "$out" 'job `scope` in .github/workflows/freshness.yml writes outputs a condition reads and runs a script of the repository from the checkout')"
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = './scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'"
nobase "the same script run by its path is refused" 1
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'case \"\$p\" in\n  scripts/scope.sh) echo suite=true >> \"\$GITHUB_OUTPUT\" ;;\nesac'"
nobase "a path that is only a pattern of a case is not a script it runs" 0
for event in pull_request_target workflow_call; do
	change freshness.yml "doc.pop(True, None); doc['on'] = {'$event': None}; doc['jobs']['scope']['steps'][1]['run'] = 'bash ./scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'"
	nobase "a scope step that runs the checkout's script in a workflow run by $event is refused" 1
done
change freshness.yml "doc['on'] = {'schedule': [{'cron': '0 0 * * *'}]}; doc['jobs']['scope']['steps'][1]['run'] = 'bash ./scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'; doc.pop(True, None)"
nobase "a workflow no pull request can run may run the script of its own checkout" 0
BYTES=$'name: Freshness\non: pull_request\njobs:\n  published-bytes-ready:\n    runs-on: ubuntu-latest\n    outputs:\n      ready: ${{ steps.check.outputs.ready }}\n    steps:\n      - id: check\n        run: bash ./scripts/monitoring/check-schedule-history-ready.sh >> "$GITHUB_OUTPUT"\n  freshness-published-bytes:\n    needs: published-bytes-ready\n    if: needs.published-bytes-ready.outputs.ready == \'true\'\n    uses: ./.github/workflows/reusable-schedule-freshness.yml\n'
printf '%s' "$BYTES" > "$G/.github/workflows/freshness.yml"
nobase "the producer the rule lists as running its checkout's script is accepted" 0
sed -i 's/published-bytes-ready:$/ready-too:/; s/needs: published-bytes-ready/needs: ready-too/; s/needs\.published-bytes-ready/needs.ready-too/' "$G/.github/workflows/freshness.yml"
nobase "the same producer under another job id is refused" 1

out="$(run_base "$G" 0000000000000000000000000000000000000000)"; rc=$?
check "a base that is named and cannot be read stops the rule" "1" "$rc"
check "and says so" "1" "$(said "$out" 'cannot be read')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
