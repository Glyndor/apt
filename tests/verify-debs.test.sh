#!/usr/bin/env bash
#
# Tests for scripts/verify-debs.sh — the fail-closed gate that admits a product
# .deb only when its detached Ed25519 signature verifies against a trusted
# release key. Each case asserts the script's exit status (0 = admitted,
# non-zero = rejected) so a regression that lets an unverified or reserved-name
# package through fails CI.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$HERE/scripts/verify-debs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# assert <expected-exit> <description> -- <command...>
assert() {
	local want="$1" desc="$2"
	shift 3 # drop want, desc, and the literal "--"
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want, got $got)"
		fail=$((fail + 1))
	fi
}

# assert_error <expected-exit> <needle> <description> -- <command...>
# Same as assert, but also requires the combined stdout+stderr to contain
# needle, so a rejection is checked for the right reason, not just any exit.
assert_error() {
	local want="$1" needle="$2" desc="$3"
	shift 4 # drop want, needle, desc, and the literal "--"
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF "$needle"; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got: $out)"
		fail=$((fail + 1))
	fi
}

# Build a .deb with a given control Package name into $WORK, echo its path.
make_deb() {
	local name="$1" pkg="$2" root
	root="$WORK/root-$name"
	mkdir -p "$root/DEBIAN"
	cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: 1.0
Architecture: amd64
Maintainer: Glyndor <packages@glyndor.net>
Description: test fixture
EOF
	dpkg-deb --root-owner-group --build "$root" "$WORK/$name.deb" >/dev/null
	echo "$WORK/$name.deb"
}

# Generate the signing key and the committed-style public key file(s).
python3 - "$WORK" <<'PYEOF'
import base64
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

work = sys.argv[1]
key = Ed25519PrivateKey.generate()
wrong = Ed25519PrivateKey.generate().public_key()


def b64(pub):
	raw = pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
	return base64.b64encode(raw).decode()


with open(os.path.join(work, "priv.b64"), "w") as f:
	f.write(base64.b64encode(
		key.private_bytes(
			serialization.Encoding.Raw,
			serialization.PrivateFormat.Raw,
			serialization.NoEncryption(),
		)
	).decode())

# Single trusted key.
with open(os.path.join(work, "key.b64"), "w") as f:
	f.write(b64(key.public_key()) + "\n")

# Two keys (wrong first, right second) — exercises rotation-overlap admit-if-any.
with open(os.path.join(work, "keys-multi.b64"), "w") as f:
	f.write("# glyndor release keys\n")
	f.write(b64(wrong) + "\n")
	f.write(b64(key.public_key()) + "\n")

# Only-wrong key — nothing should verify against it.
with open(os.path.join(work, "key-wrong.b64"), "w") as f:
	f.write(b64(wrong) + "\n")
PYEOF

# Sign <file> into <file>.sig with the generated private key.
sign() {
	python3 - "$WORK/priv.b64" "$1" <<'PYEOF'
import base64
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

priv_b64, path = sys.argv[1], sys.argv[2]
with open(priv_b64) as f:
	key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(f.read()))
with open(path, "rb") as f:
	data = f.read()
with open(path + ".sig", "wb") as f:
	f.write(key.sign(data))
PYEOF
}

# --- Case 1: a valid, signed product .deb is admitted. ---
d="$WORK/case1"; mkdir -p "$d"
deb="$(make_deb good podup)"; cp "$deb" "$d/"; sign "$d/good.deb"
assert 0 "valid signature is admitted" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 2: a missing .sig is rejected. ---
d="$WORK/case2"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/"
assert 1 "missing signature is rejected" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 3: a tampered .deb is rejected. ---
d="$WORK/case3"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/good.deb"; cp "$d/../case1/good.deb.sig" "$d/good.deb.sig"
printf 'tamper' >> "$d/good.deb"
assert 1 "tampered package is rejected" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 4: multi-key file admits a .deb the second key signed. ---
d="$WORK/case4"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/good.deb"; cp "$WORK/case1/good.deb.sig" "$d/good.deb.sig"
assert 0 "multi-key file admits a valid package" -- "$VERIFY" "$d" "$WORK/keys-multi.b64"

# --- Case 5: a key file that does not match is rejected. ---
d="$WORK/case5"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/good.deb"; cp "$WORK/case1/good.deb.sig" "$d/good.deb.sig"
assert 1 "non-matching key rejects a valid signature" -- "$VERIFY" "$d" "$WORK/key-wrong.b64"

# --- Case 6: a validly-signed .deb whose control Package is the reserved
#            keyring name is rejected (cannot shadow the local keyring). ---
d="$WORK/case6"; mkdir -p "$d"
deb="$(make_deb evil glyndor-archive-keyring)"; cp "$deb" "$d/"; sign "$d/evil.deb"
assert 1 "reserved keyring package name is rejected" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 7: a .deb whose control data dpkg-deb cannot read is rejected even
#            with a valid signature (the reserved-name gate must never be
#            skipped for an unclassifiable package). ---
d="$WORK/case7"; mkdir -p "$d"
printf 'not a real debian package' > "$d/garbage.deb"; sign "$d/garbage.deb"
assert 1 "unreadable package control is rejected" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 8: a validly-signed .deb whose control Package does not match the
#            expected_package argument is rejected — the shared release key
#            lets any product sign a .deb, so a product's identity must also
#            be bound to the product it claims to be, not just checked for a
#            valid signature. ---
d="$WORK/case8"; mkdir -p "$d"
deb="$(make_deb mismatch podup)"; cp "$deb" "$d/"; sign "$d/mismatch.deb"
assert_error 1 "package name mismatch" "control Package mismatching expected_package is rejected" \
	-- "$VERIFY" "$d" "$WORK/key.b64" otherproduct

# --- Case 9: a .deb whose control Package matches expected_package but whose
#            filename does not carry the "<expected_package>_" prefix is
#            rejected — matching the control field alone would still admit a
#            relabeled asset. ---
d="$WORK/case9"; mkdir -p "$d"
deb="$(make_deb wrongname podup)"; cp "$deb" "$d/"; sign "$d/wrongname.deb"
assert_error 1 "package name mismatch" "filename not prefixed with expected_package is rejected" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup

# --- Case 10: the three-argument form admits a .deb whose control Package
#             and filename both match the expected product. ---
d="$WORK/case10"; mkdir -p "$d"
deb="$(make_deb podup_1.0_amd64 podup)"; cp "$deb" "$d/"; sign "$d/podup_1.0_amd64.deb"
assert 0 "three-arg form admits a correctly-named package" -- "$VERIFY" "$d" "$WORK/key.b64" podup

# --- Case 11: the reserved keyring filename is rejected even when the
#             control Package field is an ordinary product name — the
#             filename itself must never be able to shadow the locally-built
#             keyring package. ---
d="$WORK/case11"; mkdir -p "$d"
deb="$(make_deb glyndor-archive-keyring_1.0_amd64 podup)"; cp "$deb" "$d/"
sign "$d/glyndor-archive-keyring_1.0_amd64.deb"
assert_error 1 "reserved keyring name" "reserved keyring filename is rejected" \
	-- "$VERIFY" "$d" "$WORK/key.b64"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
