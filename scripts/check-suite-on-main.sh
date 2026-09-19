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
# WHY THIS JOB BRANCHES ON GITHUB_EVENT_NAME:
#
#   On a push, the question is "what happened to the commit I just pushed", not
#   "what is the newest completed run on the branch". Measured on 2026-09-19:
#   after `main` had been red, the push that fixed it ran this job at the same
#   instant it ran tests.yml, and the job asked the API for the newest
#   COMPLETED tests.yml run on `main`, which at that instant was the previous
#   commit's still-red run. The push's own tests.yml was green, and the job
#   reported the older run as the verdict, so the developer pushing the fix saw
#   a red cross from this job on the run that proved their fix. The same shape
#   had happened twice before with `per_page=1`: the API did not always put the
#   newest run at the head of the page (Glyndor/apt#249 on 2026-09-08,
#   Glyndor/scoop-bucket#173 on 2026-09-17), and a one-item page returned a run
#   from days earlier while a newer verdict existed.
#
#   The push path now lists runs of `tests.yml` on `main` with `per_page=30`,
#   picks the newest one whose `head_sha` is `GITHUB_SHA`, and if it has no
#   verdict yet, waits 15 seconds and looks again, for up to 32 attempts (eight
#   minutes, inside the job's ten-minute bound). A push that lands while the
#   suite is still running is the case this loop exists for, and the worst case
#   it costs is the eight minutes the suite takes. A `cancelled` run for the
#   pushed commit itself is red: nothing newer can answer for that commit, so
#   the only honest verdict is the one the run reached.
#
#   On schedule and pull_request the question is the same as before: the newest
#   completed run on the branch. The fix is to read a 30-item page and take the
#   greatest `created_at`, because the API does not always put the newest run at
#   the head of a filtered page. `cancelled` runs are passed over and counted:
#   a cancelled run only means a newer push superseded it, and the next tick
#   reads the newer verdict.
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
# Environment: GH_TOKEN, which on a runner is the job's own GITHUB_TOKEN.
#   GITHUB_EVENT_NAME selects the path (push vs schedule/pull_request).
#   GITHUB_SHA is the commit to look up on the push path. It reads nothing
#   beyond this repository's own run history, and reading that needs
#   `actions: read` alongside `contents: read`, or the call is refused.
set -euo pipefail

repo="${1:-}"
workflow="${2:-}"
branch="${3:-main}"

if [ -z "$repo" ] || [ -z "$workflow" ]; then
	echo "usage: check-suite-on-main.sh <owner/repo> <workflow-file> [branch]" >&2
	exit 2
fi

event="${GITHUB_EVENT_NAME:-}"
sha="${GITHUB_SHA:-}"

# --- the push path -----------------------------------------------------------
#
# The job and tests.yml start at the same instant on push, so the run for
# `GITHUB_SHA` may not have a verdict yet. The loop polls for up to 8
# minutes (32 attempts of 15 seconds); the job's 10-minute bound is the
# outer limit. The lookup is unfiltered by status so a run still in flight
# is visible; only `head_sha` selects the run that answers for the push.
# A `cancelled` run for that head_sha is red: nothing newer can answer
# for the commit that was pushed.

push_report_no_verdict() {
	local short="${sha:0:7}"
	echo "::error::no $workflow run for commit $short on $branch finished within 8 minutes" >&2
	echo "  This job polled the API from the instant tests.yml for that commit started and" >&2
	echo "  saw no completed verdict in 8 minutes, so the state of $branch for that commit is" >&2
	echo "  unknown rather than green. A run for that commit may still be in flight, or the" >&2
	echo "  suite never started for it. Open the workflow run list on $branch to see which." >&2
	exit 1
}

if [ "$event" = "push" ] && [ -n "$sha" ]; then
	url="repos/${repo}/actions/workflows/${workflow}/runs?branch=${branch}&per_page=30"
	# Pick the newest run whose head_sha is the commit that was pushed, sort
	# by created_at so the page order does not decide the verdict. `id` is the
	# tie-breaker for runs created in the same second, which the API does emit.
	filter='[.workflow_runs[] | select(.head_sha=="'"$sha"'")]
		| sort_by(.created_at, .id) | reverse | .[0]
		| [(.status // ""), (.conclusion // ""), (.run_number | tostring),
		   (.head_sha // ""), (.created_at // ""), (.html_url // "")]
		| @tsv'

	run=""
	for attempt in $(seq 1 32); do
		run="$(gh api "$url" --jq "$filter")"
		if [ -n "$run" ]; then
			IFS=$'\t' read -r status _ <<<"$run"
			if [ "$status" = "completed" ]; then
				break
			fi
			run=""
		fi
		if [ "$attempt" -lt 32 ]; then
			sleep 15
		fi
	done

	if [ -z "$run" ]; then
		push_report_no_verdict
	fi

	IFS=$'\t' read -r status conclusion number rsha created rurl <<<"$run"
	rshort="${rsha:0:7}"

	if [ "$conclusion" != "success" ]; then
		echo "::error::$workflow concluded '$conclusion' on $branch for commit $rshort: run #$number, started $created" >&2
		echo "  $rurl" >&2
		echo "  The verdict is the run for $rshort, which is the commit the push brought in." >&2
		echo "  Read that run before anything else lands on top of it: a second push onto a" >&2
		echo "  red commit buries which change was responsible. This check is deliberately" >&2
		echo "  not a required one, so it cannot block the push that repairs $branch." >&2
		exit 1
	fi

	echo "$workflow on $branch for commit $rshort: run #$number concluded $conclusion (started $created)."
	exit 0
fi

# --- the schedule and pull_request path --------------------------------------
#
# The newest completed run on the branch, but read from a 30-item page and
# sorted by `created_at` here. A one-item page does not always carry the
# newest run (Glyndor/apt#249, Glyndor/scoop-bucket#173). `cancelled` runs
# are passed over and counted; a page where every completed run was
# cancelled fails with a no-verdict message, distinct from an empty page
# which keeps the unknown-state failure.

run="$(gh api \
	"repos/${repo}/actions/workflows/${workflow}/runs?branch=${branch}&status=completed&per_page=30" \
	--jq '.workflow_runs[]
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

newest_line=""
newest_created=""
cancelled_count=0
total_count=0
while IFS=$'\t' read -r rstatus rconclusion rnumber rsha rcreated rurl; do
	[ -z "$rstatus" ] && continue
	total_count=$((total_count + 1))
	if [ "$rconclusion" = "cancelled" ]; then
		cancelled_count=$((cancelled_count + 1))
		continue
	fi
	if [ -z "$newest_created" ] || [ "$rcreated" \> "$newest_created" ]; then
		newest_created="$rcreated"
		newest_line="$rstatus	$rconclusion	$rnumber	$rsha	$rcreated	$rurl"
	fi
done <<<"$run"

if [ -z "$newest_line" ]; then
	echo "::error::no verdict from completed runs of $workflow on $branch: all $total_count completed runs were cancelled" >&2
	echo "  A cancelled run is the absence of a verdict, not one, and every completed run in" >&2
	echo "  the last 30 is absent. A newer push that superseded them will produce its own" >&2
	echo "  completed run on the next tick; this job will read that one then." >&2
	exit 1
fi

IFS=$'\t' read -r status conclusion number sha created url <<<"$newest_line"
short="${sha:0:7}"

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

if [ "$cancelled_count" -gt 0 ]; then
	echo "$workflow on $branch: run #$number for $short concluded $conclusion (started $created)."
	echo "  Passed over $cancelled_count cancelled run(s) that a newer push superseded."
else
	echo "$workflow on $branch: run #$number for $short concluded $conclusion (started $created)."
fi
