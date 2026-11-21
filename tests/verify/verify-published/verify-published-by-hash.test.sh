#!/usr/bin/env bash
#
# Tests for the by-hash leg of scripts/verify/verify-published.sh. An index
# that says `Acquire-By-Hash: yes` makes apt ask for every file it declares as
# <its directory>/by-hash/SHA256/<sha256>, so those are the names a client
# fetches, and a copy that is missing or holds other bytes fails `apt update`
# the way a missing Packages does. The read-back checks each one.
#
# The archive comes from tests/fixtures/verify/verify-published-fixture.sh and
# is offered by hash with scripts/build/add-by-hash.sh, the script the build
# uses, so the case that passes is the shape a publish uploads.
#
# Requires: gpg, gpgv, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/fixtures/verify/verify-published-fixture.sh
. "$HERE/tests/fixtures/verify/verify-published-fixture.sh"

pass=0
fail=0

by_hash() { bash "$HERE/scripts/build/add-by-hash.sh" "$DIST" "$TRUSTED_KEY" "$TRUSTED_ASC" >/dev/null; }
# copy_of <path>: the by-hash name of a file the signed index declares.
copy_of() {
	local sha
	sha="$(awk -v p="$1" '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $3 == p { print $1 }' "$DIST/Release")"
	printf '%s/by-hash/SHA256/%s\n' "$DIST/$(dirname "$1")" "$sha"
}
resign() {
	gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
		--local-user "$TRUSTED_KEY" --clearsign --output "$DIST/InRelease" "$DIST/Release"
	gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
		--local-user "$TRUSTED_KEY" --armor --detach-sign --output "$DIST/Release.gpg" "$DIST/Release"
}

build_archive; by_hash
assert_says 0 "by-hash index file(s)" "the control: an index offered by hash, with every copy served, is accepted" -- run

build_archive; by_hash
rm "$(copy_of main/binary-arm64/Packages)"
assert_error 1 "by-hash index file(s) are not being served as signed" \
	"a by-hash copy the signed index implies and the archive does not serve is rejected" -- run
build_archive; by_hash
rm "$(copy_of main/binary-arm64/Packages)"
assert_error 1 "unreachable: main/binary-arm64/by-hash/SHA256/" "naming the copy" -- run

build_archive; by_hash
copy="$(copy_of main/binary-amd64/Packages)"
LC_ALL=C tr 'abcdefghijklmnopqrstuvwxyz' 'bcdefghijklmnopqrstuvwxyza' < "$copy" > "$WORK/rotated" && cat "$WORK/rotated" > "$copy"
assert_error 1 "hash mismatch: main/binary-amd64/by-hash/SHA256/" \
	"a by-hash copy that holds other bytes of the same size is rejected" -- run

# Without the field apt asks for the fixed names only, and those are read back
# above, so the copies are not asked for. Deleting one proves it was not read.
build_archive
assert_says 0 "does not offer Acquire-By-Hash" "an index without the field is accepted and says it was not offered" -- run
build_archive; by_hash
sed -i '/^Acquire-By-Hash: yes$/d' "$DIST/Release"; resign
rm "$(copy_of main/binary-arm64/Packages)"
assert 0 "and a copy is not asked for when the field is gone" -- run

# apt reads other spellings of yes as yes, and this archive writes only `yes`,
# so any other value is a signed index this check cannot say it has read.
build_archive; by_hash
sed -i 's/^Acquire-By-Hash: yes$/Acquire-By-Hash: true/' "$DIST/Release"; resign
assert_error 1 "Acquire-By-Hash: true" "a field with another value is rejected" -- run

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
