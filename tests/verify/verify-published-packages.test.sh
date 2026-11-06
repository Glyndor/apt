#!/usr/bin/env bash
#
# Tests for how scripts/verify/verify-published.sh reads a verified Packages
# file: the third link of the chain, from the signed index to the .deb files an
# apt client installs.
#
# The parser has to see EVERY stanza. Two stanzas that lost the blank line
# between them were read as one, only the last one's fields survived, and the
# first package was never fetched: a publish stayed green over a file that was
# missing from the bucket. A path made only of dots is also not a plain relative
# path, and the check that says so must say it for `.` and `..` too.
#
# The archive, the keys and the local HTTP server come from
# tests/verify/verify-published-fixture.sh.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/verify/verify-published-fixture.sh
. "$HERE/tests/verify/verify-published-fixture.sh"

pass=0
fail=0

# --- Stanzas without a separator ---------------------------------------------

build_archive
assert 0 "the control: an intact archive is accepted" -- run

build_archive
# Drop every blank line, so each architecture's stanzas run into one another,
# then make the first package unreachable. A parser that keeps only the last
# stanza's fields never asks for it.
for arch in amd64 arm64; do
	sed -i '/^$/d' "$DIST/main/binary-$arch/Packages"
done
write_release "$TRUSTED_KEY"
rm "$SITE/$PODUP_POOL/podup_1.12.0_amd64.deb"
assert_error 1 "podup_1.12.0_amd64.deb" \
	"a package whose stanza lost its separator is still verified" -- run

# --- Paths made only of dots -------------------------------------------------

for bad in . .. ./x a/./b a/.; do
	build_archive
	sed -i "s|Filename: $PODUP_POOL/podup_1.12.0_amd64.deb|Filename: $bad|" \
		"$DIST/main/binary-amd64/Packages"
	write_release "$TRUSTED_KEY"
	assert_error 1 "not a plain relative path" \
		"the declared path '$bad' is rejected" -- run
done

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
