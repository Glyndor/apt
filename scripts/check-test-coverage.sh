#!/usr/bin/env bash
#
# Fail when a script in scripts/ has no matching tests/<name>.test.sh.
#
# This file lives in scripts/, so it is in its own input set and needs its own
# test like anything else here. Removing that test, or exempting this file,
# turns tests/check-test-coverage.test.sh red. A gate that exempts itself is how
# a checker ends up being the only unchecked thing in the repository.
#
# It asserts one direction only: every script has a test. The reverse -- a test
# with no script -- is a different failure with a different fix, and folding
# both into one check would make the message ambiguous. tests/ also holds tests
# for things that are not scripts at all, such as the README bootstrap.
#
# Usage: check-test-coverage.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$root/scripts" ] || { echo "no scripts/ directory under $root" >&2; exit 1; }

missing=()
for script in "$root"/scripts/*.sh; do
	# The glob stays literal when nothing matches, so check before using it.
	[ -e "$script" ] || continue
	name="$(basename "$script" .sh)"
	[ -f "$root/tests/$name.test.sh" ] || missing+=("scripts/$name.sh")
done

if [ ${#missing[@]} -gt 0 ]; then
	echo "::error::${#missing[@]} script(s) in scripts/ have no test in tests/:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "Add tests/<name>.test.sh, or explain in the pull request why the script is untestable." >&2
	exit 1
fi

echo "test coverage: every script in scripts/ has a test."
