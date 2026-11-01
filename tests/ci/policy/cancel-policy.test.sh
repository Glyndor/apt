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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
