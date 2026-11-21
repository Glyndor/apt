#!/usr/bin/env bash
#
# scripts/verify/verify-debs.sh binds a package to its product, its release and its
# architecture with the Package, Version and Architecture control fields. Those fields
# have to be read from the bytes the release key verified: read from the file again, a
# change between the two reads gives the fields of one package and the signature of
# another, and the binding is computed over data nobody signed.
#
# A dpkg-deb on PATH stands for whoever can write to the directory: the first time it is
# asked for the field a case names, it replaces the package in the directory with another
# file, and then answers as usual. That is every order in which the file can change
# before it is read: before the Package field, before the Version, before the Architecture.
#
#   - the replacement has the same fields as the signed package and other bytes: the
#     fields agree and only the comparison at the end can tell, so it is refused for that;
#   - the signed package declares another product, release or architecture and the
#     replacement declares the right one: what is read is the signed one, so it is refused
#     for the field it declares, which the file in the directory would have hidden.
#
# Each refusal is paired with the same package left alone, which is admitted, so a fixture
# refused for another reason cannot satisfy it, and each case shows the swap took place.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-debs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# assert_error <expected-exit> <needle> <description> -- <command...>
assert_error() {
	local want="$1" needle="$2" desc="$3"
	shift 4
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got: $out)"
		fail=$((fail + 1))
	fi
}

# check <description> <expected> <actual>
check() {
	if [ "$2" = "$3" ]; then
		echo "ok   - $1"
		pass=$((pass + 1))
	else
		echo "FAIL - $1 (want '$2', got '$3')"
		fail=$((fail + 1))
	fi
}

# make_deb <path> <package> <version> <architecture> <description>: a package at <path>.
make_deb() {
	local root="$WORK/root-$RANDOM$RANDOM"
	mkdir -p "$root/DEBIAN"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: %s\n' \
		"$2" "$3" "$4" "$5" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$1" >/dev/null
}

python3 -I - "$WORK/key.b64" "$WORK/priv.b64" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.generate()
open(sys.argv[1], "w").write(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode() + "\n")
open(sys.argv[2], "wb").write(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption()))
PY

sign() { # <file>: <file>.sig with the key the cases trust
	python3 -I - "$WORK/priv.b64" "$1" <<'PY'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[2] + ".sig", "wb").write(k.sign(open(sys.argv[2], "rb").read()))
PY
}

# dpkg-deb that, the first time it is asked for SWAP_FIELD, puts SWAP_WITH over SWAP_TARGET
# and leaves SWAP_DONE behind; then it answers as usual.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/dpkg-deb" <<STUB
#!/bin/sh
if [ "\$1" = -f ] && [ "\$3" = "\${SWAP_FIELD:-}" ] && [ ! -e "\$SWAP_DONE" ]; then
	cp "\$SWAP_WITH" "\$SWAP_TARGET"
	: > "\$SWAP_DONE"
fi
exec $(command -v dpkg-deb) "\$@"
STUB
chmod 755 "$WORK/stub/dpkg-deb"

# fixture <name> <package> <version> <architecture>: a directory holding the signed package
# podup_1.0.0_amd64.deb with those fields, and the replacement podup_1.0.0 with the right
# ones and other bytes, at $WORK/<name>.swap.
fixture() {
	D="$WORK/$1"
	mkdir -p "$D"
	make_deb "$D/podup_1.0.0_amd64.deb" "$2" "$3" "$4" "the signed package"
	sign "$D/podup_1.0.0_amd64.deb"
	make_deb "$WORK/$1.swap" podup 1.0.0 amd64 "another package with the same fields"
	rm -f "$WORK/$1.done"
}
run() { # <name> <field the swap waits for, or empty>
	env PATH="$WORK/stub:$PATH" SWAP_FIELD="$2" SWAP_TARGET="$WORK/$1/podup_1.0.0_amd64.deb" \
		SWAP_WITH="$WORK/$1.swap" SWAP_DONE="$WORK/$1.done" "$VERIFY" "$WORK/$1" "$WORK/key.b64" podup v1.0.0
}
swapped() { [ -e "$WORK/$1.done" ] && echo yes || echo no; }

fixture honest podup 1.0.0 amd64
assert_error 0 "verified podup_1.0.0_amd64.deb" "a package nobody touches is admitted" -- run honest ""
check "and the stub did nothing there" no "$(swapped honest)"

# The replacement carries the signed package's fields and other bytes.
for field in Package Version Architecture; do
	fixture "same-$field" podup 1.0.0 amd64
	assert_error 1 "podup_1.0.0_amd64.deb changed while it was being verified" \
		"a package replaced before its $field is read is refused for the change" -- run "same-$field" "$field"
	check "  and the file was replaced in that case" yes "$(swapped "same-$field")"
	check "  and it holds the replacement's bytes" yes "$(cmp -s "$WORK/same-$field/podup_1.0.0_amd64.deb" "$WORK/same-$field.swap" && echo yes || echo no)"
done

# The signed package declares what the replacement hides.
fixture liar-package other 1.0.0 amd64
assert_error 1 "package name mismatch: podup_1.0.0_amd64.deb declares 'other'" \
	"the signed Package is what is read, not the one of the file put in its place" -- run liar-package Package
check "  and the file was replaced in that case" yes "$(swapped liar-package)"
fixture liar-version podup 9.9.9 amd64
assert_error 1 "version mismatch: podup_1.0.0_amd64.deb declares '9.9.9'" \
	"the signed Version is what is read, not the one of the file put in its place" -- run liar-version Version
check "  and the file was replaced in that case" yes "$(swapped liar-version)"
fixture liar-arch podup 1.0.0 arm64
assert_error 1 "architecture mismatch: podup_1.0.0_amd64.deb is named for amd64 but its control field says arm64" \
	"the signed Architecture is what is read, not the one of the file put in its place" -- run liar-arch Architecture
check "  and the file was replaced in that case" yes "$(swapped liar-arch)"

# The same signed packages with nothing put in their place are refused for the same fields, so
# the three refusals above come from the signed bytes and not from the swap.
for liar in package:other:1.0.0:amd64:"package name mismatch" version:podup:9.9.9:amd64:"version mismatch" arch:podup:1.0.0:arm64:"architecture mismatch"; do
	IFS=: read -r name pkg ver arch needle <<<"$liar"
	fixture "bare-$name" "$pkg" "$ver" "$arch"
	assert_error 1 "$needle" "the $name liar left alone is refused for the same field" -- run "bare-$name" ""
	check "  and the stub did nothing there" no "$(swapped "bare-$name")"
done

# The verified bytes have to be kept before anything is decided: a copy that cannot be
# written is refused for that, and the same package is admitted where it can.
fixture nospace podup 1.0.0 amd64
assert_error 1 "could not keep a private copy of the verified bytes of podup_1.0.0_amd64.deb" \
	"a copy that cannot be written is refused for that" -- bash -c 'ulimit -f 0; exec "$@"' _ "$VERIFY" "$WORK/nospace" "$WORK/key.b64" podup v1.0.0
assert_error 0 "verified podup_1.0.0_amd64.deb" "and the same package is admitted where it can" -- run nospace ""

# Without a private directory there is nowhere to keep them, and nothing is read from the file.
fixture nodir podup 1.0.0 amd64
assert_error 1 "cannot create a private directory to hold the verified packages" \
	"a private directory that cannot be made is refused for that" -- env TMPDIR="$WORK/no-such-directory" "$VERIFY" "$WORK/nodir" "$WORK/key.b64" podup v1.0.0
assert_error 0 "verified podup_1.0.0_amd64.deb" "and the same package is admitted where it can" -- run nodir ""

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
