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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
