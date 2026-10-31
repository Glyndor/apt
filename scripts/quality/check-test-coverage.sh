#!/usr/bin/env bash
#
# Fail when a script in scripts/<area>/ has no matching tests/<area>/<name>.test.sh.
#
# This file lives in scripts/, so it is in its own input set and needs its own
# test like anything else here. Removing that test, or exempting this file,
# turns tests/quality/check-test-coverage.test.sh red. A gate that exempts itself is how
# a checker ends up being the only unchecked thing in the repository.
#
# It asserts one direction only: every script has a test. The reverse -- a test
# with no script -- is a different failure with a different fix, and folding
# both into one check would make the message ambiguous. tests/ also holds tests
# for things that are not scripts at all, such as the README bootstrap.
#
# Usage: check-test-coverage.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -d "$root/scripts" ] || { echo "no scripts/ directory under $root" >&2; exit 1; }

# Any depth under scripts/: scripts/<area>/x.sh needs tests/<area>/x.test.sh, and a
# script that sits loose in scripts/ is covered by tests/x.test.sh. The test must
# mirror the script's folder, so moving a script without its test is a failure
# and not a silent pass because a same-named test exists somewhere else.
missing=()
while IFS= read -r -d '' script; do
	rel="${script#"$root"/scripts/}"
	rel="${rel%.sh}"
	[ -f "$root/tests/$rel.test.sh" ] || missing+=("scripts/$rel.sh")
done < <(find "$root/scripts" -type f -name '*.sh' -print0 | LC_ALL=C sort -z)

if [ ${#missing[@]} -gt 0 ]; then
	echo "::error::${#missing[@]} script(s) in scripts/ have no test in the same folder of tests/:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "Add tests/<area>/<name>.test.sh, or explain in the pull request why the script is untestable." >&2
	exit 1
fi

echo "test coverage: every script in scripts/ has a test."
