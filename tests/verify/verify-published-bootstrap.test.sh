#!/usr/bin/env bash
#
# Tests for the bootstrap pair of scripts/verify/verify-published.sh: the two
# files the install line actually fetches.
#
# Nobody arrives as an apt client. The first command a stranger runs pipes the
# installer into a root shell, and that installer fetches two files from the
# ROOT of the archive, outside dists/ and outside pool/. Every case in
# tests/verify/verify-published.test.sh walks the chain apt walks and reaches
# neither of them.
#
# The archive, the keys and the local HTTP server come from
# tests/fixtures/verify/verify-published-fixture.sh. The index and the pool are in
# tests/verify/verify-published.test.sh, and the budgets and caps are in
# tests/verify/verify-published-budget.test.sh.
#
# Each case asserts the script's exit status (0 = archive consistent,
# non-zero = rejected) so a regression that lets a broken archive through
# fails CI.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/fixtures/verify/verify-published-fixture.sh
. "$HERE/tests/fixtures/verify/verify-published-fixture.sh"

pass=0
fail=0

# --- The bootstrap pair: what the install line actually fetches --------------

build_archive
rm "$SITE/glyndor-archive-keyring.deb"
assert_error 1 "glyndor-archive-keyring.deb" "a missing bootstrap package is rejected" -- run

build_archive
# The root copy diverging from the pool object is the case the signed index can
# catch and nothing else can: same name, different bytes, and apt never looks.
printf 'a different keyring deb\n' > "$SITE/glyndor-archive-keyring.deb"
assert_error 1 "mismatch" "a bootstrap package that is not the signed one is rejected" -- run

build_archive
rm "$SITE/glyndor-archive-keyring.deb.asc"
assert_error 1 "does not verify against the archive key" "a bootstrap package served without its signature is rejected" -- run

build_archive
# A real signature over the real bytes, by a key the archive does not publish.
# This is the one the installer cannot catch on its own: it reads the key out of
# the package it just downloaded, while this script holds the published key.
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$UNTRUSTED_KEY" --armor --detach-sign \
	--output "$SITE/glyndor-archive-keyring.deb.asc" \
	"$SITE/glyndor-archive-keyring.deb"
assert_error 1 "does not verify against the archive key" "a bootstrap signature by an untrusted key is rejected" -- run

build_archive
# A valid signature by the right key over DIFFERENT bytes, which is what an
# attacker keeps when they rebuild the package around the published key.
printf 'other bytes\n' > "$WORK/other"
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign \
	--output "$SITE/glyndor-archive-keyring.deb.asc" "$WORK/other"
assert_error 1 "does not verify against the archive key" "a bootstrap signature made over other bytes is rejected" -- run

build_archive
: > "$SITE/glyndor-archive-keyring.deb.asc"
assert_error 1 "does not verify against the archive key" "an empty bootstrap signature is rejected" -- run

build_archive
# An archive that carries no keyring package at all cannot be bootstrapped, and
# saying "0 of 0 verified" over it would be the emptiest kind of green.
sed -i '/^Package: glyndor-archive-keyring$/,/^$/d' \
	"$DIST/main/binary-amd64/Packages" "$DIST/main/binary-arm64/Packages"
write_release "$TRUSTED_KEY"
assert_error 1 "declare no glyndor-archive-keyring" "an archive declaring no keyring package is rejected" -- run

build_archive
assert_says 0 "bootstrap keyring package and its signature are served as signed" \
	"a consistent archive says its bootstrap pair was checked" -- run

build_archive
# One object, fetched once. The stanza parser used to emit the matching entry
# twice, because awk's `exit` runs END on its way out and END's guard was still
# true, and the gate then downloaded and checked the same package twice while
# reporting "all 2". Every other case here passed straight through it: they
# assert refusals and the closing message, and a duplicate changes neither.
# Asserting the count is what makes the duplicate visible.
assert_says 0 "all 1 bootstrap package(s)" \
	"the bootstrap package is counted once, not once per parse path" -- run

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
