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

# --- Case 2: a missing .sig is rejected, and for that reason. Without the
#            needle this case stayed green with the existence check deleted:
#            the verifier then failed to open the .sig and reported it as a
#            tampered release, which is the wrong diagnosis for an operator
#            whose product simply forgot to attach the signature. ---
d="$WORK/case2"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/"
assert_error 1 "no signature" "missing signature is rejected as missing, not as tampered" \
	-- "$VERIFY" "$d" "$WORK/key.b64"

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
#            The fixture is valid in every respect except the one under test:
#            its filename carries the expected prefix, so only the control
#            field can be what refuses it, and the needle names that field.
#            The earlier fixture was named mismatch.deb, which the filename
#            check also refused with the same first words, so this case
#            stayed green with the control-field check deleted. ---
d="$WORK/case8"; mkdir -p "$d"
deb="$(make_deb otherproduct_1.0_amd64 podup)"; cp "$deb" "$d/"; sign "$d/otherproduct_1.0_amd64.deb"
assert_error 1 "declares 'podup', expected 'otherproduct'" \
	"control Package mismatching expected_package is rejected for the control field" \
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

# --- Case 12: an oversized signature file is rejected by a bounded read
#             instead of being read into memory wholesale before the length is
#             known. ---
d="$WORK/case12"; mkdir -p "$d"
deb="$(make_deb oversized podup)"; cp "$deb" "$d/"; sign "$d/oversized.deb"
head -c 5000 /dev/zero > "$d/oversized.deb.sig"
assert_error 1 "over 4096 bytes" "oversized signature file is rejected" \
	-- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 13: a malformed local trust file — the release public key itself
#             fails to load — is diagnosed as our bug and must not be
#             reported as "release may be tampered": that message points
#             whoever is debugging it at an attack that isn't there, when
#             the real cause is our own committed key file. ---
d="$WORK/case13"; mkdir -p "$d"
deb="$(make_deb good2 podup)"; cp "$deb" "$d/"; sign "$d/good2.deb"
printf 'not-valid-base64!!\n' > "$WORK/key-malformed.b64"
assert_error 1 "local release trust file is malformed" \
	"malformed local trust file is diagnosed, not reported as tampered" \
	-- "$VERIFY" "$d" "$WORK/key-malformed.b64"

# --- Case 14: an empty .deb directory fails closed with the right message,
#             so a product whose downloads all failed (release retired, 404,
#             network) cannot publish an archive that claims "verified 0
#             packages" with exit 0. The empty-array check at verify-debs.sh
#             depends on `shopt -s nullglob` to actually produce an empty
#             array when the glob has no matches; that option is what makes
#             this control exercisable, and removing either line 50 (the
#             shopt) or line 52 (the check itself) takes this test red —
#             verified by mutation on the PR branch. ---
d="$WORK/case14"; mkdir -p "$d"
assert_error 1 "no .deb files to verify" \
	"an empty .deb directory fails closed rather than admitting zero packages" \
	-- "$VERIFY" "$d" "$WORK/key.b64"

echo
# --- Case 14: a trust file that carries no key is refused as such. -------------
#             A comment-only file parses cleanly and yields zero keys; without
#             this check the loop below it would verify against nothing and
#             report every package as tampered, which sends the operator to
#             chase a signature instead of the trust file. ---
d="$WORK/case14"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/"; cp "$WORK/case1/good.deb.sig" "$d/"
printf '# no keys here\n\n' > "$WORK/key-none.b64"
assert_error 1 "has no keys" "a trust file with no key is refused for having no key" \
	-- "$VERIFY" "$d" "$WORK/key-none.b64"

# --- Case 15: a trust file that does not exist is refused as missing. ----------
#             Without the existence check the read loop below it dies under
#             set -e with a bash error, or reaches the no-keys refusal, and
#             either sends the operator to look at the wrong thing. ---
d="$WORK/case15"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/"; cp "$WORK/case1/good.deb.sig" "$d/"
assert_error 1 "not found" "a trust file that does not exist is refused as missing" \
	-- "$VERIFY" "$d" "$WORK/does-not-exist.b64"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
