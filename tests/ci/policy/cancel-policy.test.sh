#!/usr/bin/env bash
#
# A run is cancelled by a newer one only on a pull request. On a push to main
# each commit has to be judged on its own, because the suite-on-main watcher
# reads those verdicts, and a scheduled run must not be replaced by the next.
# A workflow with a concurrency group that cancels unconditionally turns two
# quick merges into one verdict and one silently missing one.
#
# Workflows that only ever run for pull requests, and ones that serialise
# publication with `cancel-in-progress: false`, are not in scope.
# The planted workflows are written with printf in single quotes, and GitHub expressions stay literal.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# Workflows that run on push or schedule as well as on pull requests.
for name in reusable-shell-ci reusable-workflow-lint reusable-line-limit \
	reusable-schedule-freshness reusable-dependabot-freshness; do
	f="$HERE/.github/workflows/$name.yml"
	line="$(grep -E '^  cancel-in-progress:' "$f" | head -1)"
	check "$name cancels only on a pull request" \
		"  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$line"
done

# A workflow that fires on a schedule is never replaced by the next run.
for f in "$HERE"/.github/workflows/*.yml; do
	name="$(basename "$f" .yml)"
	case "$name" in reusable-*) continue ;; esac
	grep -q '^  schedule:' "$f" || continue
	line="$(grep -E '^  cancel-in-progress:' "$f" | head -1)"
	check "$name does not cancel a scheduled run unconditionally" "0" \
		"$(printf '%s' "$line" | grep -c 'cancel-in-progress: true')"
done

# The second comparison in drift.yml has to run even when the first one failed.
if [ -f "$HERE/.github/workflows/drift.yml" ] && grep -q 'check-render-drift.sh' "$HERE/.github/workflows/drift.yml"; then
	# shellcheck disable=SC2016 # a GitHub expression, literal on purpose
	check "the render comparison in drift.yml runs after a failure of the reusable one" "1" \
		"$(grep -B4 'check-render-drift.sh' "$HERE/.github/workflows/drift.yml" | grep -c 'if: ${{ !cancelled() }}')"
fi

# --- outside a pull request the group is unique per run ----------------------------
#
# `cancel-in-progress: false` is not enough on its own. With a group shared by every
# push, GitHub keeps the running job and still cancels an older PENDING one when a newer
# is queued, so two quick merges lose the verdict of the first, and the suite-on-main
# watcher reads a cancelled run as red. A pull request wants the opposite: one shared
# group per ref, so a newer push replaces the superseded run. The group that does both
# says so in its own text:
#
#   ${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
#
# The rule: in a workflow that can run on a push (it triggers on `push`, or it is a
# reusable workflow and so cannot know what calls it), a `group:` that names
# `github.ref` has to carry that exact form. A workflow that only runs for pull requests
# or on a schedule is not in scope: no push can queue behind another there.
#
# The checker is shown to refuse each way of getting it wrong before it is trusted with
# the live workflows.
PER_RUN="github.event_name == 'pull_request' && github.ref || github.run_id"

# One line per offence, "<file>: <group line>".
ref_groups_not_per_run() { # <workflows dir>
	local f line
	for f in "$1"/*.yml; do
		[ -f "$f" ] || continue
		grep -qE '^  (push|workflow_call):' "$f" || continue
		while IFS= read -r line; do
			case "$line" in *"$PER_RUN"*) continue ;; esac
			printf '%s: %s\n' "$(basename "$f")" "${line#"${line%%[![:space:]]*}"}"
		done < <(grep -E '^[[:space:]]*group:.*github\.ref' "$f")
	done
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/planted"
# shellcheck disable=SC2016 # GitHub expressions, literal on purpose
{
	printf 'on:\n  workflow_call:\nconcurrency:\n  group: a-${{ github.workflow }}-${{ github.ref }}\n' > "$WORK/planted/reusable-shared.yml"
	printf 'on:\n  pull_request:\n  push:\n    branches: [main]\njobs:\n  j:\n    concurrency:\n      group: b-${{ github.ref }}\n' > "$WORK/planted/push-job.yml"
	printf 'on:\n  push:\nconcurrency:\n  group: c-${{ github.ref || github.run_id }}\n' > "$WORK/planted/half-form.yml"
	printf 'on:\n  workflow_call:\nconcurrency:\n  group: d-${{ github.event_name == '"'"'pull_request'"'"' && github.ref || github.run_id }}\n' > "$WORK/planted/reusable-per-run.yml"
	printf 'on:\n  pull_request:\nconcurrency:\n  group: e-${{ github.ref }}\n' > "$WORK/planted/pull-request-only.yml"
	printf 'on:\n  schedule:\n    - cron: "0 * * * *"\nconcurrency:\n  group: f-${{ github.ref }}\n' > "$WORK/planted/schedule-only.yml"
}
planted="$(ref_groups_not_per_run "$WORK/planted")"
planted_count() { printf '%s\n' "$planted" | grep -c "^$1: "; }
check "a reusable workflow whose group names only the ref is reported" "1" "$(planted_count reusable-shared.yml)"
check "a group on a job of a workflow that triggers on push is reported" "1" "$(planted_count push-job.yml)"
check "a group that falls back to the run id without the event test is reported" "1" "$(planted_count half-form.yml)"
check "a reusable workflow whose group carries the per-run form is accepted" "0" "$(planted_count reusable-per-run.yml)"
check "a workflow that only runs for pull requests is not in scope" "0" "$(planted_count pull-request-only.yml)"
check "a workflow that only runs on a schedule is not in scope" "0" "$(planted_count schedule-only.yml)"
check "the planted tree has exactly the three offences" "3" "$(printf '%s\n' "$planted" | grep -c .)"

live="$(ref_groups_not_per_run "$HERE/.github/workflows")"
check "no live workflow that can run on a push shares its group between pushes" "" "$live"

# --- the security checks are only ever replaced by a newer run of the same pull request ---
#
# The audit, the secret scan, the commit identity and the sign-off count for merging, and a
# run that is cancelled is not a pass. They may be cancelled only by a newer run of the SAME
# pull request, which runs them again on the newer commit: a workflow that holds one and
# cancels unconditionally has to say, in its group, that outside a pull request every run
# is its own.
SECURITY_JOB='^  (dco|commit-identity|secret-scan|audit|brew-audit):|uses: .*reusable-dco'
# One line per offence: a workflow with a security job that can run outside a pull request (or is
# called by one that does), cancels, and whose group is not per run.
security_cancels_across_runs() { # <workflows dir>
	local f
	for f in "$1"/*.yml; do
		[ -f "$f" ] || continue
		grep -qE "$SECURITY_JOB" "$f" || continue
		grep -qE '^  (push|schedule|workflow_call|merge_group):' "$f" || continue
		grep -qE '^[[:space:]]*cancel-in-progress:[[:space:]]*(true|\$\{\{ *github\.event_name)' "$f" || continue
		grep -qF "$PER_RUN" "$f" && continue
		grep -qE '^[[:space:]]*group:.*github\.run_id' "$f" && continue
		printf '%s\n' "$(basename "$f")"
	done
}
mkdir -p "$WORK/security"
printf 'on:\n  pull_request:\n  push:\nconcurrency:\n  group: s-${{ github.workflow }}\n  cancel-in-progress: true\njobs:\n  secret-scan:\n    runs-on: x\n' > "$WORK/security/shared.yml"
printf 'on:\n  pull_request:\nconcurrency:\n  group: s-${{ github.event_name == '"'"'pull_request'"'"' && github.ref || github.run_id }}\n  cancel-in-progress: true\njobs:\n  secret-scan:\n    runs-on: x\n' > "$WORK/security/per-run.yml"
printf 'on:\n  pull_request:\nconcurrency:\n  group: s-${{ github.workflow }}\n  cancel-in-progress: true\njobs:\n  build:\n    runs-on: x\n' > "$WORK/security/no-security.yml"
found="$(security_cancels_across_runs "$WORK/security")"
check "a workflow that holds a security check and cancels in a shared group is reported" "shared.yml" "$found"
check "no live workflow that holds a security check cancels it across runs" "" "$(security_cancels_across_runs "$HERE/.github/workflows")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
