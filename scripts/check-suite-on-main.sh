#!/usr/bin/env bash
#
# Fail when the newest COMPLETED run of a workflow on a branch did not succeed.
#
# The suite reports on the commit it ran for, and that is enough for as long as
# the pull request is open. It stops being enough the moment the pull request
# merges. A run that is still reporting when the merge lands finishes against a
# closed pull request, and its result is shown to nobody: measured on
# 2026-09-06, the suite stayed red on `main` for twenty minutes in two of the
# three channel repositories, and the only reason anyone found out is that
# somebody went looking.
#
# The freshness watchers cannot see it. They ask the API for
# `event=schedule&status=success`, so a failing run is absent from the answer by
# construction; they measure whether a cron still fires, not whether the thing
# it fired passed. A commit-author check cannot see it either: who wrote a
# commit is not what happened to it.
#
# WHY THE NEWEST COMPLETED RUN RATHER THAN SIMPLY THE NEWEST:
#
#   A run still in flight has no conclusion. Reading it as one would paint every
#   ordinary merge red for the two minutes the suite takes, and a check that is
#   red for a normal event is a check people learn to click past. Asking for
#   `status=completed` makes the API skip past it to the newest run that reached
#   a verdict, which is what the state of the branch actually is.
#
# WHY ANY CONCLUSION OTHER THAN success IS REPORTED:
#
#   `cancelled` and `timed_out` are not evidence that the branch passes. They
#   are the absence of evidence, and treating the absence of evidence as a green
#   light is the whole reason this went unreported. The cost is one honest red
#   line when two merges land inside the suite's own runtime and the older run
#   is cancelled by the newer one; the next tick clears it.
#
# WHY AN EMPTY ANSWER IS REPORTED RATHER THAN PASSED OVER:
#
#   A checker that inspected nothing prints the same success line as one that
#   inspected everything. That has shipped in this repository before, where
#   line-limit reported every file within its limit on every pull request while
#   never opening a workflow. An empty history means the state of the branch is
#   unknown, and unknown is not green.
#
# Usage: check-suite-on-main.sh <owner/repo> <workflow-file> [branch]
#   <owner/repo>     repository whose run history is read, e.g. Glyndor/apt
#   <workflow-file>  file name of the suite workflow, e.g. tests.yml
#   [branch]         branch whose state is read; default main
#
# Environment: GH_TOKEN, which on a runner is the job's own GITHUB_TOKEN. It
# reads nothing beyond this repository's own run history, and reading that needs
# `actions: read` alongside `contents: read`, or the call is refused.
set -euo pipefail

repo="${1:-}"
workflow="${2:-}"
branch="${3:-main}"

if [ -z "$repo" ] || [ -z "$workflow" ]; then
	echo "usage: check-suite-on-main.sh <owner/repo> <workflow-file> [branch]" >&2
	exit 2
fi

# One call and one run. The API returns runs newest first, so `per_page=1`
# alongside `status=completed` is the newest run that reached a verdict.
# `status` travels back with the rest because the filter is the API's promise
# and the guard below is this script's own.
run="$(gh api \
	"repos/${repo}/actions/workflows/${workflow}/runs?branch=${branch}&status=completed&per_page=1" \
	--jq '.workflow_runs[0] // empty
		| [(.status // ""), (.conclusion // ""), (.run_number | tostring),
		   (.head_sha // ""), (.created_at // ""), (.html_url // "")]
		| @tsv')"

if [ -z "$run" ]; then
	echo "::error::no completed run of $workflow on $branch is on record" >&2
	echo "  Nothing was inspected, so this is not a pass: the state of $branch is unknown." >&2
	echo "  Either the workflow has never finished a run on $branch, or it was renamed and" >&2
	echo "  this check still names the file it used to have. Confirm that $workflow is the" >&2
	echo "  suite that runs on $branch, then read the next run rather than this one." >&2
	exit 1
fi

IFS=$'\t' read -r status conclusion number sha created url <<<"$run"
short="${sha:0:7}"

# The request asked for completed runs only. An answer carrying anything else
# means the query is wrong, not that the branch is broken, and the two have to
# read differently: a reader sent to look for a failure that is really a run in
# flight learns to distrust the check.
if [ "$status" != "completed" ]; then
	echo "::error::the newest run of $workflow on $branch came back with status '$status', not 'completed'" >&2
	echo "  This is a fault in the query rather than a verdict on $branch. A run still in" >&2
	echo "  flight has no conclusion to report, so the request must carry status=completed." >&2
	exit 1
fi

if [ "$conclusion" != "success" ]; then
	echo "::error::$workflow concluded '$conclusion' on $branch: run #$number for $short, started $created" >&2
	echo "  $url" >&2
	echo "  $branch is broken now, and the pull request that broke it is already closed, so" >&2
	echo "  nothing else reports this. Read the run above before anything else lands on top" >&2
	echo "  of it: a second merge onto a red branch buries which change was responsible." >&2
	echo "  This check is deliberately not a required one, so it cannot block the pull" >&2
	echo "  request that repairs $branch." >&2
	exit 1
fi

echo "$workflow on $branch: run #$number for $short concluded $conclusion (started $created)."
