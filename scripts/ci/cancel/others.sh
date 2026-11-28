#!/usr/bin/env bash
#
# Cancel the sibling runs of one commit, and nothing else.
#
# A pull request runs several workflows. One of them fails, the others keep
# burning a runner until they finish, and the pull request waits for verdicts
# nobody reads. This script cancels the siblings of the commit whose work is
# already lost: the expensive functional work.
#
# WHAT IT CANCELS
#
#   * only runs of the `pull_request` event, of the same head branch and of
#     the same commit: the cancellation belongs to one pull request, not to the
#     commit. A run of `push`, `merge_group`, `schedule` or `workflow_dispatch`
#     is never cancelled, even when it shares the commit;
#   * the head commit and the event are what keep it inside one pull request
#     when the branch of a pull request of a fork carries the name of a branch
#     of this repository: the head commit of the fork is not the head commit
#     of the branch of this repository that carries the same name, so only the
#     runs of the head commit of the event and of the `pull_request` event are
#     cancelled;
#   * only when a run of that commit has failed or has timed out. A commit
#     whose work is all green is left alone, and so is one that has not been
#     judged yet: the cancellation buys nothing before the failure;
#   * only the workflows named in CANCELLABLE_WORKFLOWS;
#   * only runs that have not finished: a finished run has nothing to cancel;
#   * never its own run: the job that runs this script is not cancelled by it.
#
# WHAT IT NEVER CANCELS
#
#   A security analysis: CodeQL, the dependency audits, the secret scan and the
#   DCO. A functional failure must not leave a commit without its analysis.
#   NEVER_CANCELLED_WORKFLOWS wins over CANCELLABLE_WORKFLOWS, so a name that
#   ends up in both lists is not cancelled.
#
#   The run of a fork. Another pull request of a fork can share the branch and
#   the commit of this one, so the repository of the run that fired this one
#   is what tells the two apart: only a run of this repository may cancel.
#
#   The freshness watcher. It is no required check: its verdict holds no merge
#   back and nothing waits for it, so the work of the other workflows is still
#   worth finishing.
#
# CANCELLING DOES NOT TURN A RED PULL REQUEST GREEN
#
#   A cancelled sibling keeps the verdict it had, and a cancelled check is not
#   a pass: the aggregator of the pull request still fails for the original
#   failure. What is cancelled is the work, not the verdict.
#
# THE VALUES ARRIVE THROUGH THE ENVIRONMENT
#
#   HEAD_SHA and HEAD_BRANCH are read from the pull request and reach this
#   script through `env:`; GITHUB_REPOSITORY is the environment of the runner.
#   They never arrive as arguments and never reach a command line as text.
#
#   Four values of the run that fired this one arrive the same way: the event
#   it came from, the repository it belongs to, its verdict and the name of
#   its workflow. They are read before anything is listed or cancelled, and
#   they are compared as text, never as a pattern. They are never printed: a
#   value that a fork controls would end up in the log of this repository.
#
# A FAILURE HERE IS NOT A FAILURE OF THE JOB
#
#   This job gates nothing. A listing that fails, or a cancellation the API
#   refuses, is reported and the script ends with success: a flaky call must
#   not turn a pull request red, and the runs it did not cancel keep running
#   to the end.
#
# Requires: bash, gh and python3 (only to read the list the API returns).
set -uo pipefail

: "${HEAD_SHA:?HEAD_SHA is required: the commit whose runs may be cancelled}"
: "${HEAD_BRANCH:?HEAD_BRANCH is required: the branch whose runs may be cancelled}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required: the repository whose runs are cancelled}"

# THE RUN THAT FIRED THIS ONE
#
#   Four values of it arrive through the environment: the event it came from,
#   the repository it belongs to, its verdict and the name of its workflow.
#   A value that is empty or absent is a value that says nothing, and nothing
#   said is no reason to cancel: the script ends with success.
#
#   The comparisons are with text, one literal at a time, and the values are
#   never printed: a value that a fork controls would end up in the log of
#   this repository.
TRIGGER_EVENT="${TRIGGER_EVENT:-}"
TRIGGER_REPOSITORY="${TRIGGER_REPOSITORY:-}"
TRIGGER_CONCLUSION="${TRIGGER_CONCLUSION:-}"
TRIGGER_WORKFLOW="${TRIGGER_WORKFLOW:-}"

if [ "$TRIGGER_EVENT" != "pull_request" ]; then
	echo "::notice::the run that fired this one is not a pull request; nothing was cancelled."
	exit 0
fi

if [ "$TRIGGER_REPOSITORY" != "$GITHUB_REPOSITORY" ]; then
	echo "::notice::the run that fired this one belongs to another repository; nothing was cancelled."
	exit 0
fi

if [ "$TRIGGER_CONCLUSION" != "failure" ] && [ "$TRIGGER_CONCLUSION" != "timed_out" ]; then
	echo "::notice::the run that fired this one did not fail; nothing was cancelled."
	exit 0
fi

if [ -z "$TRIGGER_WORKFLOW" ] || [ "$TRIGGER_WORKFLOW" = "Freshness" ]; then
	echo "::notice::the run that fired this one has no workflow name or is the freshness watcher, which is no required check; nothing was cancelled."
	exit 0
fi

# The expensive functional work of this repository: the suites, the mutation
# run and the freshness watcher. A workflow that is not named here is never
# cancelled.
CANCELLABLE_WORKFLOWS=(
	"Tests"
	"Mutation"
	"Freshness"
)

# The security analyses. This list wins over the one above: a name in both is
# not cancelled. The names are matched as text, so "secret scan" covers
# "Secret scan" and "secret-scan", and "commit hygiene" covers the workflow
# that holds the secret scan.
NEVER_CANCELLED_WORKFLOWS=(
	"CodeQL"
	"CodeQL (advanced)"
	"audit"
	"dependency audit"
	"secret scan"
	"commit identity"
	"commit hygiene"
	"DCO"
	"Signed-off-by"
)

cancellable="$(printf '%s\n' "${CANCELLABLE_WORKFLOWS[@]}")"
never="$(printf '%s\n' "${NEVER_CANCELLED_WORKFLOWS[@]}")"

runs="$(mktemp "${TMPDIR:-/tmp}/cancel-others.XXXXXX")" || runs=""
if [ -z "$runs" ]; then
	echo "::notice::no temporary file was available; nothing was cancelled."
	exit 0
fi
trap 'rm -f "$runs"' EXIT

if ! gh run list --repo "$GITHUB_REPOSITORY" --event pull_request --branch "$HEAD_BRANCH" \
	--commit "$HEAD_SHA" --limit 100 \
	--json databaseId,workflowName,event,headBranch,headSha,status,conclusion >"$runs"; then
	echo "::notice::the runs of this pull request could not be listed; nothing was cancelled."
	exit 0
fi

targets="$(
	env CANCELLABLE_LIST="$cancellable" NEVER_LIST="$never" \
		HEAD_SHA="$HEAD_SHA" HEAD_BRANCH="$HEAD_BRANCH" OWN_RUN="${GITHUB_RUN_ID:-}" \
		python3 -I - "$runs" <<'PY'
import json
import os
import sys

# A run that can still be cancelled. A finished one has nothing to cancel.
CANCELLABLE_STATUS = ("queued", "in_progress", "waiting", "requested", "pending")

# The verdicts that make the rest of the work pointless.
FAILURES = ("failure", "timed_out")


def norm(text):
    """The name of a workflow, reduced to letters and digits and single spaces."""
    flat = "".join(ch if ch.isalnum() else " " for ch in str(text).lower())
    return " ".join(flat.split())


def patterns(name):
    return [norm(x) for x in os.environ.get(name, "").splitlines() if x.strip()]


cancellable = set(patterns("CANCELLABLE_LIST"))
never = patterns("NEVER_LIST")
head_sha = os.environ.get("HEAD_SHA", "")
head_branch = os.environ.get("HEAD_BRANCH", "")
own = os.environ.get("OWN_RUN", "")

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        runs = json.load(handle)
except (OSError, ValueError) as error:
    print("::notice::the list of runs could not be read (%s); nothing is cancelled." % error, file=sys.stderr)
    sys.exit(0)

if not isinstance(runs, list):
    print("::notice::the list of runs is not a list of runs; nothing is cancelled.", file=sys.stderr)
    sys.exit(0)

# The runs of this pull request, whatever workflow they belong to. A failure
# or a timeout in any of them is what makes the rest of the work pointless.
# The event and the head commit are what keep the list inside one pull
# request: the branch of a pull request of a fork can carry the name of a
# branch of this repository, and the head commit is what tells the two apart.
mine = [
    run
    for run in runs
    if isinstance(run, dict)
    and str(run.get("event") or "") == "pull_request"
    and str(run.get("headBranch") or "") == head_branch
    and str(run.get("headSha") or "") == head_sha
]
if not any(str(run.get("conclusion") or "") in FAILURES for run in mine):
    print("no run of this commit has failed; nothing is cancelled.", file=sys.stderr)
    sys.exit(0)

for run in mine:
    if str(run.get("status") or "") not in CANCELLABLE_STATUS:
        continue
    name = str(run.get("workflowName") or "")
    key = norm(name)
    if key not in cancellable:
        continue
    if any(pattern in key for pattern in never):
        continue
    identifier = str(run.get("databaseId", ""))
    if own and identifier == own:
        continue
    print("%s\t%s" % (identifier, name))
PY
)"
status=$?
if [ "$status" -ne 0 ]; then
	echo "::notice::the list of runs could not be read; nothing is cancelled."
	exit 0
fi
if [ -z "$targets" ]; then
	echo "nothing was cancelled."
	exit 0
fi


cancelled=0
while IFS=$'\t' read -r identifier name; do
	[ -n "$identifier" ] || continue
	if gh run cancel "$identifier" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
		echo "cancelled run $identifier of $name"
		cancelled=$((cancelled + 1))
	else
		echo "::notice::run $identifier of $name could not be cancelled; it may have finished."
	fi
done <<<"$targets"

echo "cancelled $cancelled run(s) of this pull request (head $HEAD_SHA)"
