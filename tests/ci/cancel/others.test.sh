#!/usr/bin/env bash
#
# The cancel job and the script it runs, against a false `gh`.
#
# A pull request runs several workflows. One of them fails and the others keep
# burning a runner until they finish. The script in scripts/ci/cancel/others.sh
# stops them, and the job in .github/workflows/cancel-others.yml is the only
# thing in this repository that holds a token with `actions: write`.
#
# WHAT IS HERE
#
#   * the script, against a false `gh` that lists what the fixture says and
#     writes down what it was asked to cancel: a run of another event, of
#     another branch or of another commit, the run of the job itself, a
#     workflow outside the list, the four security analyses and a run that has
#     already finished are none of them cancelled;
#   * the two lists of the script, read from its source: a security analysis in
#     the list of what may be cancelled is what the red case is, and the list
#     of what may never be cancelled has to cover CodeQL, the dependency
#     audit, the secret scan and the DCO;
#   * the job with the write token, read from the workflow: it holds the write
#     alone, it interpolates no expression in the text of its `run:`, its
#     checkout names no `ref:` and no `repository:`, its `env:` takes from the
#     event nothing but the head commit, the head branch and the token, and it
#     runs the script of the default branch from the working tree;
#   * the names of the list of what may be cancelled: each of them has to be
#     the `name:` of a workflow of this repository, because a name no workflow
#     carries cancels nothing.
#
# Every rule is read over the real files and over copies that break it one way
# each, so a rule that cannot run is not read as a pass: the copies have to
# turn it red for the reason it names.
#
# Requires: bash, python3 with PyYAML.
# The fixtures plant and expect literal `${{ }}` expressions of a workflow, so the
# single quotes that keep them literal are on purpose in the whole file.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/ci/cancel/others.sh"
WORKFLOW="$HERE/.github/workflows/cancel-others.yml"
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

# --- the false `gh` -----------------------------------------------------------
#
# `gh run list` prints the fixture and writes down the call it was given,
# `gh run cancel` writes the run id down. It is the only thing the script
# reaches outside itself, and it never talks to the network.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FALSE_GH'
#!/usr/bin/env bash
# The false `gh` of this test.
set -u
case "${1:-}" in
	run)
		shift
		case "${1:-}" in
			list)
				printf '%s\n' "$*" >> "$GH_CALLS_LOG"
				cat "$GH_RUNS_FILE"
				exit 0
				;;
			cancel)
				shift
				printf '%s\n' "${1:-}" >> "$GH_CANCEL_LOG"
				exit 0
				;;
		esac
		;;
esac
exit 0
FALSE_GH
chmod +x "$BIN/gh"

# --- the fixtures -------------------------------------------------------------

# One run as the API returns it.
run_json() { # <id> <workflow> <event> <branch> <sha> <status> <conclusion>
	printf '{"databaseId": %s, "workflowName": "%s", "event": "%s",' "$1" "$2" "$3"
	printf ' "headBranch": "%s", "headSha": "%s", "status": "%s", "conclusion": %s}' "$4" "$5" "$6" "$7"
}

# The runs of one commit, and the script run against them. The runs it asked
# to cancel are left in $LOG, the call it listed them with in $WORK/calls.txt
# and what it said in $WORK/output.txt.
with_runs() { # <the script to run> <run json>...
	local script="$1" run sep=""
	shift
	{
		printf '['
		for run in "$@"; do
			printf '%s%s' "$sep" "$run"
			sep=','
		done
		printf ']'
	} >"$WORK/runs.json"
	LOG="$WORK/cancelled.txt"
	: >"$LOG"
	: >"$WORK/calls.txt"
	GH_RUNS_FILE="$WORK/runs.json" GH_CANCEL_LOG="$LOG" GH_CALLS_LOG="$WORK/calls.txt" \
		HEAD_SHA="aaaa" HEAD_BRANCH="feature" \
		GITHUB_REPOSITORY="Glyndor/apt" GITHUB_RUN_ID="114" GH_TOKEN="token" \
		PATH="$BIN:$PATH" bash "$script" >"$WORK/output.txt" 2>&1
}

cancelled_ids() { # the runs the false `gh` was asked to cancel
	tr '\n' ' ' <"$LOG" | sed -e 's/[[:space:]]*$//'
}

# The names of one list of the script, read from its source.
list_of() { # <the name of the array>
	awk -v name="$1" '
		$0 == name"=(" { inside = 1; next }
		inside && /^\)/ { inside = 0; next }
		inside {
			gsub(/^[ \t]+|[ \t]+$/, "")
			gsub(/"/, "")
			if ($0 != "") print
		}
	' "$SCRIPT"
}

# A name reduced to letters and digits, the way the script compares them.
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' '; }

# The names of the list of what may never be cancelled.
never_list="$(list_of NEVER_CANCELLED_WORKFLOWS)"
cancellable_list="$(list_of CANCELLABLE_WORKFLOWS)"

# --- the script, against the false `gh` ---------------------------------------

# The commit is red: the DCO failed and the three expensive siblings are still
# running. They are the ones the cancellation is for.
with_runs "$SCRIPT" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 101 Tests pull_request feature aaaa in_progress null)" \
	"$(run_json 102 Mutation pull_request feature aaaa in_progress null)" \
	"$(run_json 103 Freshness pull_request feature aaaa queued null)"
check "the sibling runs of a commit that failed are cancelled" "101 102 103" "$(cancelled_ids)"

# Nothing has failed yet: the work is still worth finishing.
with_runs "$SCRIPT" \
	"$(run_json 101 Tests pull_request feature aaaa completed '"success"')" \
	"$(run_json 102 Mutation pull_request feature aaaa in_progress null)"
check "a commit whose work is green is left alone" "" "$(cancelled_ids)"

# A run of another event, of another branch or of another commit.
with_runs "$SCRIPT" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 104 Tests push feature aaaa in_progress null)" \
	"$(run_json 105 Tests pull_request other aaaa in_progress null)" \
	"$(run_json 106 Tests pull_request feature bbbb in_progress null)"
check "a run of another event, branch or commit is not cancelled" "" "$(cancelled_ids)"

# The branch of a pull request of a fork can carry the name of a branch of this
# repository. The head commit and the event are what tell the two apart: only
# the runs of the head commit of the event, and of the `pull_request` event,
# are cancelled.
with_runs "$SCRIPT" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 120 Tests pull_request feature bbbb in_progress null)" \
	"$(run_json 121 Tests pull_request feature aaaa in_progress null)"
check "a run of the same branch name and of another commit is not cancelled" "121" "$(cancelled_ids)"

# The listing itself asks for the event and the commit, so the runs of another
# event or of another commit never reach the script.
check "the runs are listed for the pull_request event" "1" \
	"$(grep -c -- '--event pull_request' "$WORK/calls.txt")"
check "the runs are listed for the head commit" "1" \
	"$(grep -c -- '--commit aaaa' "$WORK/calls.txt")"
check "the runs are listed for the head branch" "1" \
	"$(grep -c -- '--branch feature' "$WORK/calls.txt")"

# The run of the job that runs the script.
with_runs "$SCRIPT" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 114 Tests pull_request feature aaaa in_progress null)"
check "the run of this job is not cancelled by it" "" "$(cancelled_ids)"

# A workflow that is not in the list.
with_runs "$SCRIPT" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 107 Drift pull_request feature aaaa in_progress null)"
check "a workflow outside the list is not cancelled" "" "$(cancelled_ids)"

# The four analyses a failure may never take away.
for analysis in CodeQL "commit hygiene" DCO "dependency audit"; do
	with_runs "$SCRIPT" \
		"$(run_json 100 Workflow pull_request feature aaaa completed '"failure"')" \
		"$(run_json 110 "$analysis" pull_request feature aaaa in_progress null)"
	check "the analysis $analysis is not cancelled" "" "$(cancelled_ids)"
done

# A run that has already finished has nothing to cancel.
with_runs "$SCRIPT" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 113 Tests pull_request feature aaaa completed '"success"')"
check "a run that has finished is not cancelled" "" "$(cancelled_ids)"

# The list of what may never be cancelled wins over the other one, even when a
# name is in both.
COPY="$WORK/with-codeql.sh"
awk '/^CANCELLABLE_WORKFLOWS=\($/ { print; printf "\t\"CodeQL\"\n"; next } { print }' \
	"$SCRIPT" >"$COPY"
if cmp -s "$SCRIPT" "$COPY"; then
	echo "FIXTURE INERT: the copy is the script"
fi
with_runs "$COPY" \
	"$(run_json 100 DCO pull_request feature aaaa completed '"failure"')" \
	"$(run_json 109 CodeQL pull_request feature aaaa in_progress null)"
check "an analysis named in the cancellable list is still not cancelled" "" "$(cancelled_ids)"

# --- the two lists of the script, read from its source ------------------------

# A name of the cancellable list that is one of the analyses.
offenders=""
while IFS= read -r name; do
	[ -n "$name" ] || continue
	key="$(norm "$name")"
	while IFS= read -r pattern; do
		[ -n "$pattern" ] || continue
		case "$key" in
			*"$(norm "$pattern")"*) offenders="$offenders $name" ;;
		esac
	done <<<"$never_list"
done <<<"$cancellable_list"
check "no workflow of the cancellable list is an analysis of security" "" "$offenders"

# The list of what may never be cancelled has to cover the four analyses.
covers() { # <the name of an analysis>: 1 when a pattern of the list matches it
	local pattern
	while IFS= read -r pattern; do
		[ -n "$pattern" ] || continue
		case "$(norm "$1")" in
			*"$(norm "$pattern")"*) return 0 ;;
		esac
	done <<<"$never_list"
	return 1
}
for analysis in CodeQL "dependency audit" "secret scan" DCO; do
	check "the never-cancelled list covers $analysis" "1" \
		"$(covers "$analysis" && echo 1 || echo 0)"
done

# --- the workflow --------------------------------------------------------------

# The workflow reacts to the workflows the script may cancel, and to no other.
workflow_list="$(python3 -I - "$WORKFLOW" <<'PY'
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
on = doc.get("on", doc.get(True)) or {}
event = on.get("workflow_run") or {}
print("\n".join(event.get("workflows") or []))
PY
)"
check "the workflow reacts to the workflows the script may cancel" \
	"$(printf '%s\n' "$cancellable_list" | sort | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')" \
	"$(printf '%s\n' "$workflow_list" | sort | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"

# The names of the workflows of this repository, read from their `name:`.
workflow_names="$(python3 -I - "$HERE/.github/workflows" <<'PY'
import glob
import os
import sys

import yaml

root = sys.argv[1]
paths = sorted(glob.glob(os.path.join(root, "*.yml")) + glob.glob(os.path.join(root, "*.yaml")))
for path in paths:
    try:
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError):
        continue
    name = (doc or {}).get("name")
    if name:
        print(name)
PY
)"

# One line per name of the list of what may be cancelled that is not the `name:`
# of a workflow of this repository: a name no workflow carries cancels nothing.
missing_workflows() { # <the names, one per line>
	printf '%s\n' "$1" | while IFS= read -r name; do
		[ -n "$name" ] || continue
		if ! printf '%s\n' "$workflow_names" | grep -Fxq -- "$name"; then
			echo "the workflow $name is not one of this repository"
		fi
	done
}

check "every name of the list of what may be cancelled is a workflow of this repository" \
	"" "$(missing_workflows "$cancellable_list")"
check "a name no workflow of this repository carries is named" \
	"the workflow Suite of the future is not one of this repository" \
	"$(missing_workflows "$(printf '%s\nTests\nSuite of the future' "$cancellable_list")")"

# The job with the write token: it holds the write alone, it interpolates no
# expression in the text of its `run:`, its checkout names no ref and no other
# repository, and it runs the script of the default branch from the working
# tree.
write_token="$(python3 -I - "$WORKFLOW" <<'PY'
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for name, job in (doc.get("jobs") or {}).items():
    permissions = job.get("permissions") or {}
    if any(level == "write" for level in permissions.values()):
        print(name)
PY
)"
check "one job holds the write, and it is the cancel job" "cancel-others" "$write_token"

job_shape="$(python3 -I - "$WORKFLOW" <<'PY'
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
job = (doc.get("jobs") or {}).get("cancel-others")
if not isinstance(job, dict):
    sys.exit(0)
steps = job.get("steps") or []
runs = [step.get("run", "") for step in steps]
uses = [step.get("uses", "") for step in steps]
print("steps", len(steps))
print("expressions", sum(1 for text in runs if "${{" in text))
print("pinned", sum(1 for text in uses if text.startswith("actions/checkout@")
                    and len(text.split("@")[1].split()[0]) == 40))
print("checkout ref", sum(1 for step in steps if "ref" in (step.get("with") or {})))
print("checkout repository",
      sum(1 for step in steps if "repository" in (step.get("with") or {})))
print("launcher", sum(1 for text in runs if "scripts/ci/cancel/others.sh" in text))
print("base copy", sum(1 for text in runs if "git show" in text))
PY
)"
check "the cancel job has the checkout and the launcher, and nothing else" "steps 2" \
	"$(printf '%s\n' "$job_shape" | grep '^steps ')"
check "no expression is interpolated in the text of its run" "expressions 0" \
	"$(printf '%s\n' "$job_shape" | grep '^expressions ')"
check "its checkout is pinned by a commit" "pinned 1" \
	"$(printf '%s\n' "$job_shape" | grep '^pinned ')"
check "its checkout names no ref" "checkout ref 0" \
	"$(printf '%s\n' "$job_shape" | grep '^checkout ref ')"
check "its checkout names no other repository" "checkout repository 0" \
	"$(printf '%s\n' "$job_shape" | grep '^checkout repository ')"
check "it runs the script of the default branch from the working tree" "launcher 1" \
	"$(printf '%s\n' "$job_shape" | grep '^launcher ')"
check "it reads nothing from the base commit" "base copy 0" \
	"$(printf '%s\n' "$job_shape" | grep '^base copy ')"

# --- the shape the cancel job has to keep -------------------------------------
#
# A workflow triggered by `workflow_run` runs the file of the default branch,
# and its checkout is that branch too: the pull request controls neither the
# workflow nor the script. The job that holds the write may therefore not
# change what the checkout brings, may not interpolate an expression in the
# text of its `run:`, may not take from the event anything but the head
# commit, the head branch and the token, and no other job may hold the write.
#
# The rule is read over the real workflow and over copies that break it one
# way each: a rule that cannot run prints nothing and would be read as a pass.
shape_violations() { # <the workflow file>
	python3 -I - "$1" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

# The job that holds the write, and the only one that may hold it.
WRITE_JOB = "cancel-others"

# The three values the step may take: the head commit of the event, the head
# branch of the event and the token of the job.
ALLOWED_ENV = {
    "HEAD_SHA": "${{ github.event.workflow_run.head_sha }}",
    "HEAD_BRANCH": "${{ github.event.workflow_run.head_branch }}",
    "GH_TOKEN": "${{ github.token }}",
}

problems = []
jobs = (doc or {}).get("jobs") or {}

for name, job in jobs.items():
    if (job.get("permissions") or {}).get("actions") == "write" and name != WRITE_JOB:
        problems.append("the job %s holds actions: write" % name)

steps = (jobs.get(WRITE_JOB) or {}).get("steps") or []
ran = [step for step in steps if str(step.get("run") or "").strip()]
if not ran:
    problems.append("the cancel job runs no step")

for step in steps:
    if (step.get("uses") or "").startswith("actions/checkout@"):
        given = step.get("with") or {}
        for key in ("ref", "repository"):
            if key in given:
                problems.append("the checkout holds %s, so the script it runs may not be "
                                "the copy of the default branch" % key)

for step in ran:
    if "${{" in str(step.get("run") or ""):
        problems.append("the run of a step interpolates an expression, so the text of "
                        "the step is not the one of this repository")
    env = step.get("env") or {}
    for key, wanted in sorted(ALLOWED_ENV.items()):
        if key not in env:
            problems.append("the env of the step holds no %s, which the script reads" % key)
        elif env[key] != wanted:
            problems.append("the env of the step takes %s for %s, which is not the head "
                            "commit, the head branch or the token" % (env[key], key))
    for key in sorted(set(env) - set(ALLOWED_ENV)):
        problems.append("the env of the step holds %s, which is not the head commit, the "
                        "head branch or the token" % key)

for problem in problems:
    print(problem)
PY
}

# A copy of the workflow with one thing changed, and the rule read over it. A
# change that does nothing is reported, so the rule is never judged against a
# copy that still holds the shape. The answer is left in $WORK/copy.out.
fixture() { # <the sed expression>
	cp "$WORKFLOW" "$WORK/copy.yml"
	sed -i "$1" "$WORK/copy.yml"
	if cmp -s "$WORKFLOW" "$WORK/copy.yml"; then
		echo "FIXTURE INERT: $1"
	fi
	shape_violations "$WORK/copy.yml" >"$WORK/copy.out"
}

# 1 when the rule named the thing, 0 when it did not.
named() { # <the text the rule has to name>
	if grep -Fxq -- "$1" "$WORK/copy.out"; then echo 1; else echo 0; fi
}

check "the cancel job keeps the shape it needs" "" "$(shape_violations "$WORKFLOW")"

fixture 's/^          persist-credentials: false$/          persist-credentials: false\n          ref: refs\/heads\/main/'
check "a checkout that names a ref is named" "1" \
	"$(named 'the checkout holds ref, so the script it runs may not be the copy of the default branch')"

fixture 's/^          persist-credentials: false$/          persist-credentials: false\n          repository: someone\/else/'
check "a checkout that names another repository is named" "1" \
	"$(named 'the checkout holds repository, so the script it runs may not be the copy of the default branch')"

fixture 's|^        run: bash scripts/ci/cancel/others.sh$|        run: bash scripts/ci/cancel/others.sh ${{ github.event.workflow_run.head_sha }}|'
check "an expression in the text of the run is named" "1" \
	"$(named 'the run of a step interpolates an expression, so the text of the step is not the one of this repository')"

fixture 's/^jobs:$/jobs:\n  other:\n    runs-on: ubuntu-26.04\n    permissions:\n      actions: write\n    steps:\n      - run: true/'
check "another job that holds the write is named" "1" \
	"$(named 'the job other holds actions: write')"

fixture 's|^          HEAD_SHA: .*$|          HEAD_SHA: ${{ github.event.workflow_run.pull_requests[0].head.sha }}|'
check "an env that takes something else from the event is named" "1" \
	"$(named 'the env of the step takes ${{ github.event.workflow_run.pull_requests[0].head.sha }} for HEAD_SHA, which is not the head commit, the head branch or the token')"

fixture 's|^          HEAD_SHA: .*$|          HEAD_SHA: ${{ github.event.workflow_run.head_sha }}\n          BASE_SHA: ${{ github.event.workflow_run.pull_requests[0].base.sha }}|'
check "an env that holds something else is named" "1" \
	"$(named 'the env of the step holds BASE_SHA, which is not the head commit, the head branch or the token')"

fixture 's|^        run: bash scripts/ci/cancel/others.sh$|        run: ""|'
check "a job that runs no step is named" "1" \
	"$(named 'the cancel job runs no step')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
