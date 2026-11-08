#!/usr/bin/env bash
#
# Tests for the names scripts/verify/verify-published.sh saves verified index
# files under. A path is saved as the path with every `/` turned into `_`, and
# `_` is a legal character in a signed path, so `main/binary-amd64/Packages` and
# `main/binary-amd64_Packages` are two signed files with one saved name. The
# second download replaced the first, the pool was read from whichever survived,
# and the gate reported success over a Packages file it had not looked at.
#
# The signing key is the one thing this script cannot second-guess, but a
# compromised signer must make the check fail, not make it quietly check less.
#
# The archive, the keys and the local HTTP server come from
# tests/fixtures/verify/verify-published-fixture.sh.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/fixtures/verify/verify-published-fixture.sh
. "$HERE/tests/fixtures/verify/verify-published-fixture.sh"

pass=0
fail=0

build_archive
assert 0 "the control: an intact archive is accepted" -- run

build_archive
# Both files exist, are served, and match their signed hashes: nothing but the
# collision can fail this archive, so the message is the proof.
cp "$DIST/main/binary-amd64/Packages" "$DIST/main/binary-amd64_Packages"
write_release "$TRUSTED_KEY"
assert_error 1 "map to the same saved name" \
	"two signed paths that differ only in / versus _ are rejected" -- run

build_archive
# A look-alike that does not collide must still be accepted, or the guard is
# only refusing every extra index.
cp "$DIST/main/binary-amd64/Packages" "$DIST/main/binary-amd64-copy"
write_release "$TRUSTED_KEY"
assert 0 "a look-alike name that maps to a name of its own is accepted" -- run

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
