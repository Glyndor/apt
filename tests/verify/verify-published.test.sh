#!/usr/bin/env bash
#
# Tests for the index and the pool of scripts/verify/verify-published.sh, the
# gate that reads the published archive back and refuses to call a publish
# successful unless every file the signed index declares is served at exactly
# the size and hash it was signed with.
#
# The two links of the chain are separate responsibilities and are checked
# separately here. The INDEX is what the signed Release declares: its own
# signatures, its SHA256 section, and the paths it names. The POOL is what
# those paths point at: the .deb objects the index vouches for.
#
# The bootstrap pair -- the two files the install line fetches from the root
# of the archive -- is in tests/verify/verify-published-bootstrap.test.sh, and
# the budgets and caps are in
# tests/verify/verify-published-budget.test.sh. The archive, the keys and the
# local HTTP server come from tests/verify/verify-published-fixture.sh.
#
# Each case asserts the script's exit status (0 = archive consistent,
# non-zero = rejected) so a regression that lets a broken archive through
# fails CI.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/verify/verify-published-fixture.sh
. "$HERE/tests/verify/verify-published-fixture.sh"

pass=0
fail=0

# --- Cases -------------------------------------------------------------------

build_archive
assert 0 "a consistent archive is accepted" -- run

build_archive
rm "$DIST/main/binary-arm64/Packages"
assert_error 1 "main/binary-arm64/Packages" "a declared file that 404s is rejected" -- run

build_archive
printf 'Package: podup\nVersion: 1.12.0\nArchitecture: arm64\nextra\n\n' \
	> "$DIST/main/binary-arm64/Packages"
assert_error 1 "size mismatch" "a declared file served at the wrong size is rejected" -- run

build_archive
# Same length, different bytes: the size check passes and only the hash catches
# it, which is the case a size-only comparison would wave through.
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
assert_error 1 "hash mismatch" "a declared file served with the wrong content is rejected" -- run

build_archive_signed_by "$UNTRUSTED_KEY"
assert_error 1 "signature verification failed" "an index signed by an untrusted key is rejected" -- run

build_archive
cp "$DIST/Release" "$DIST/InRelease"
assert_error 1 "signature verification failed" "an unsigned index is rejected" -- run

build_archive
# Same case as above, but the unsigned fixture is valid OpenPGP: a literal data
# packet that any OpenPGP parser will accept. A plain-text "unsigned index" is
# refused as not-OpenPGP, which proves nothing about the signature rule; this
# case is what catches a verifier that accepts an unsigned packet because it
# parsed cleanly. The header (0xcb: new-format tag 11, one-octet length) keeps
# the body short enough for the one-octet length encoding to stay valid.
python3 - "$DIST/InRelease" <<'PY'
import sys
body = b"Date: Sun, 06 Sep 2026 09:47:38 UTC\nSHA256:\n abc 1 x\n"
packet = b"b\x00" + bytes(4) + body
open(sys.argv[1], "wb").write(bytes([0xcb, len(packet)]) + packet)
PY
assert_error 1 "signature verification failed" "an OpenPGP literal data packet with no signature is rejected" -- run

build_archive
rm "$DIST/Release.gpg"
assert_error 1 "detached Release" "a missing detached signature is rejected" -- run

build_archive
# Re-sign a Release that no longer matches InRelease: the archive is serving
# two different builds to two different client paths.
printf 'Origin: Glyndor\nSHA256:\n 00 1 main/binary-amd64/Packages\n' > "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign --yes \
	--output "$DIST/Release.gpg" "$DIST/Release"
assert_error 1 "different files" "an index whose detached half disagrees is rejected" -- run

build_archive
printf 'Origin: Glyndor\nSuite: stable\n' > "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --clearsign --yes --output "$DIST/InRelease" "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign --yes --output "$DIST/Release.gpg" "$DIST/Release"
assert_error 1 "declares no SHA256 entries" "an index with no SHA256 section is rejected" -- run

build_archive
# A signed document is authentic, not safe. The key that signs it is the one
# thing this script cannot second-guess, so a traversal path must still be
# refused rather than pasted into a URL.
{
	echo "Origin: Glyndor"
	echo "SHA256:"
	echo " 00 1 main/../../etc/passwd"
} > "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --clearsign --yes --output "$DIST/InRelease" "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign --yes --output "$DIST/Release.gpg" "$DIST/Release"
assert_error 1 "not a plain relative path" "a traversal path in the signed index is rejected" -- run

# The bug this script exists for: a file that is missing when the publish
# finishes and appears moments later. The restore is scheduled before the run
# so the first pass reliably misses it and a later pass reliably finds it, which
# keeps the case deterministic rather than racing the retry schedule.
build_archive
cp "$DIST/main/binary-arm64/Packages" "$WORK/delayed"
rm "$DIST/main/binary-arm64/Packages"
(sleep 2 && cp "$WORK/delayed" "$DIST/main/binary-arm64/Packages") &
restore_pid=$!
assert 0 "a file that becomes visible late is accepted after a retry" -- \
	"$VERIFY" "$BASE" "$TRUSTED_ASC" 6 1
# Wait on the restore specifically. A bare `wait` would also wait on the HTTP
# server, which is a background job of this same shell and never exits.
wait "$restore_pid"

build_archive
assert_error 1 "could not fetch" "an unreachable archive is rejected" -- \
	"$VERIFY" "http://127.0.0.1:1" "$TRUSTED_ASC" 1 0

# --- The pool: the link the indices vouch for --------------------------------

build_archive
rm "$SITE/$PODUP_POOL/podup_1.12.0_arm64.deb"
assert_error 1 "podup_1.12.0_arm64.deb" "a declared package that 404s is rejected" -- run

build_archive
# Same length, different bytes. The indices still verify; only the package does
# not, which is the case an index-only check waves through.
sed -i 's/fake podup deb for arm64/fake podup deb for ar_64/' \
	"$SITE/$PODUP_POOL/podup_1.12.0_arm64.deb"
assert_error 1 "hash mismatch" "a declared package served with the wrong content is rejected" -- run

build_archive
# Four declarations across two architectures, three distinct objects: the
# architecture-independent keyring must not be fetched once per architecture.
assert_says 0 "declare 3 package(s)" "an architecture-independent package is checked once, not per architecture" -- run

build_archive
: > "$DIST/main/binary-amd64/Packages"
: > "$DIST/main/binary-arm64/Packages"
write_release "$TRUSTED_KEY"
assert_error 1 "declare no packages" "an archive whose indices declare no installable package is rejected" -- run

build_archive
# The second link of the chain needs the same path validation as the first: a
# verified index is authentic, and authentic is still not safe.
sed -i "s|Filename: $PODUP_POOL/podup_1.12.0_amd64.deb|Filename: pool/../../etc/passwd|" \
	"$DIST/main/binary-amd64/Packages"
write_release "$TRUSTED_KEY"
assert_error 1 "not a plain relative path" "a traversal path in a verified index is rejected" -- run

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
