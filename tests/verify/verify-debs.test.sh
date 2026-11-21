#!/usr/bin/env bash
#
# Tests for scripts/verify/verify-debs.sh, the fail-closed gate that admits a product
# .deb only when its detached Ed25519 signature verifies against a trusted
# release key. Each case asserts the script's exit status (0 = admitted,
# non-zero = rejected) so a regression that lets an unverified or reserved-name
# package through fails CI.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-debs.sh"
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
	local name="$1" pkg="$2" root ver arch
	# Third argument is the Debian Version; fourth is the Architecture. Both
	# are defaulted so every existing call site keeps the values it was
	# written against (Architecture: amd64 in particular, which is what every
	# case below needs unless it explicitly asks for a different arch).
	ver="${3:-1.0}"
	arch="${4:-amd64}"
	root="$WORK/root-$name"
	mkdir -p "$root/DEBIAN"
	cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: $arch
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

# Two keys (wrong first, right second), exercising rotation-overlap admit-if-any.
with open(os.path.join(work, "keys-multi.b64"), "w") as f:
	f.write("# glyndor release keys\n")
	f.write(b64(wrong) + "\n")
	f.write(b64(key.public_key()) + "\n")

# Only-wrong key: nothing should verify against it.
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
assert_error 1 "invalid signature for" "tampered package is rejected as tampered" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 4: multi-key file admits a .deb the second key signed. ---
d="$WORK/case4"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/good.deb"; cp "$WORK/case1/good.deb.sig" "$d/good.deb.sig"
assert 0 "multi-key file admits a valid package" -- "$VERIFY" "$d" "$WORK/keys-multi.b64"

# --- Case 5: a key file that does not match is rejected. ---
d="$WORK/case5"; mkdir -p "$d"; cp "$WORK/good.deb" "$d/good.deb"; cp "$WORK/case1/good.deb.sig" "$d/good.deb.sig"
assert_error 1 "invalid signature for" "non-matching key rejects a valid signature" -- "$VERIFY" "$d" "$WORK/key-wrong.b64"

# --- Case 6: a validly-signed .deb whose control Package is the reserved
#            keyring name is rejected (cannot shadow the local keyring). ---
d="$WORK/case6"; mkdir -p "$d"
deb="$(make_deb evil glyndor-archive-keyring)"; cp "$deb" "$d/"; sign "$d/evil.deb"
assert_error 1 "declares the reserved package name" "reserved keyring package name is rejected for its name" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 7: a .deb whose control data dpkg-deb cannot read is rejected even
#            with a valid signature (the reserved-name gate must never be
#            skipped for an unclassifiable package). ---
d="$WORK/case7"; mkdir -p "$d"
printf 'not a real debian package' > "$d/garbage.deb"; sign "$d/garbage.deb"
assert_error 1 "cannot read the Package control field" "unreadable package control is rejected as unreadable" -- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 8: a validly-signed .deb whose control Package does not match the
#            expected_package argument is rejected, because the shared release key
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
#            rejected, because matching the control field alone would still admit a
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
#             control Package field is an ordinary product name, so the
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

# An Ed25519 signature is exactly 64 bytes. A shorter or longer file is refused by name, before the
# cryptographic check, so the reason for the rejection is the length and not an exception.
d="$WORK/case12b"; mkdir -p "$d"
deb="$(make_deb shortsig podup)"; cp "$deb" "$d/"; sign "$d/shortsig.deb"
head -c 63 "$d/shortsig.deb.sig" > "$d/short.sig" && mv "$d/short.sig" "$d/shortsig.deb.sig"
assert_error 1 "expected exactly 64" "a 63-byte signature file is rejected for its length" \
	-- "$VERIFY" "$d" "$WORK/key.b64"
(cd "$d" && { cat shortsig.deb.sig; printf 'x\nx'; } > long.sig && mv long.sig shortsig.deb.sig)
assert_error 1 "expected exactly 64" "a 65-byte signature file is rejected for its length" \
	-- "$VERIFY" "$d" "$WORK/key.b64"

# --- Case 13: a malformed local trust file, where the release public key
#             itself fails to load, is diagnosed as our bug and must not be
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
#             shopt) or line 52 (the check itself) takes this test red,
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

# --- Case 16: a .deb from another release is refused, which the signature -----
#             cannot catch on its own.
#
# The release key is shared and covers the bytes, never the tag they were
# attached to, and the archive is rebuilt latest-only from whatever the newest
# release carries. So an actor with release-publish rights and no signing key
# re-attaches a previously published, still validly signed .deb to a new tag.
# Measured on the real archive 2026-09-07: podup_5.4.0_amd64.deb, five releases
# behind what was being served, passed this script with exit 0.
#
# The observation that differs is the exit status for the SAME bytes under two
# different expected tags, so both halves are asserted: refused under the tag it
# does not belong to, admitted under the one it does. Without the second half a
# gate that refused everything would pass.
d="$WORK/case16"; mkdir -p "$d"
deb="$(make_deb old podup 5.4.0)"; cp "$deb" "$d/podup_5.4.0_amd64.deb"
sign "$d/podup_5.4.0_amd64.deb"
assert_error 1 "version mismatch" \
	"a .deb from an older release is refused under the current tag" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.9.2
assert 0 "and the same .deb is admitted under its own tag" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.4.0

# --- Case 17: epoch and revision belong to the packaging, not to the tag. -----
#             Comparing the whole Version string would refuse a legitimate
#             repackage, so only the upstream part is compared.
d="$WORK/case17"; mkdir -p "$d"
deb="$(make_deb repack podup 1:5.9.2-3)"; cp "$deb" "$d/podup_5.9.2_amd64.deb"
sign "$d/podup_5.9.2_amd64.deb"
assert 0 "an epoch and a Debian revision do not break the tag binding" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.9.2

# A pre-release tag carries a hyphen, which dpkg would read as the revision
# separator. The whole version equal to the tag is admitted; a different
# pre-release of the same base is still refused.
d="$WORK/case17b"; mkdir -p "$d"
deb="$(make_deb prerelease podup 5.10.0-rc1)"; cp "$deb" "$d/podup_5.10.0-rc1_amd64.deb"
sign "$d/podup_5.10.0-rc1_amd64.deb"
assert 0 "a pre-release version equal to a hyphenated tag is admitted" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.10.0-rc1
assert_error 1 "version mismatch" \
	"and the same package is refused under another pre-release of the base" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.10.0-rc2

# The same signed pre-release bytes, renamed to the stable name and offered
# under the stable tag, must be refused: cutting everything after the last
# hyphen turned 5.10.0-rc1 into 5.10.0 and admitted it as the release.
assert_error 1 "version mismatch" \
	"a signed pre-release package is refused under the stable tag" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.10.0
d="$WORK/case17d"; mkdir -p "$d"
deb="$(make_deb prerelease2 podup 5.10.0-rc1)"; cp "$deb" "$d/podup_5.10.0_amd64.deb"
sign "$d/podup_5.10.0_amd64.deb"
assert_error 1 "version mismatch" \
	"the pre-release bytes renamed to the stable filename are refused under the stable tag" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.10.0
d="$WORK/case17e"; mkdir -p "$d"
deb="$(make_deb revision podup 5.10.0-3ubuntu1)"; cp "$deb" "$d/podup_5.10.0_amd64.deb"
sign "$d/podup_5.10.0_amd64.deb"
assert 0 "a Debian revision that starts with a digit is still admitted under the stable tag" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup v5.10.0

# A key with a stray character inside it. Without validate=True, b64decode
# throws the character away and the key still decodes to 32 bytes, so a file that
# is not the key it claims to be would be trusted.
d="$WORK/case17c"; mkdir -p "$d"
deb="$(make_deb strict podup 5.9.2)"; cp "$deb" "$d/podup_5.9.2_amd64.deb"
sign "$d/podup_5.9.2_amd64.deb"
key="$(cat "$WORK/key.b64")"
printf '%s!%s\n' "${key:0:10}" "${key:10}" > "$WORK/key-stray.b64"
assert_error 1 "malformed release public key" \
	"a key with a character outside the base64 alphabet is refused" \
	-- "$VERIFY" "$d" "$WORK/key-stray.b64" podup v5.9.2

# A rotation file pasted badly: a key that is valid base64 but not 32 bytes,
# before the good one. Admit-if-any is a rule over keys, so a line that is not a
# key refuses the whole file as our own configuration error, never skipped to
# reach the next line, and never reported as a tampered release.
#
# The length is checked before the key reaches the library, which refuses it
# too, with its own wording and its own exception type. The check is what keeps
# the refusal in the malformed-trust-file branch whatever the library raises,
# and the needle is its wording, so this case is what fails when it is removed.
python3 - "$WORK/key.b64" "$WORK" <<'PYEOF'
import base64
import os
import sys

good = open(sys.argv[1]).read().strip()
work = sys.argv[2]
for size in (31, 33):
	short = base64.b64encode(os.urandom(size)).decode()
	with open(os.path.join(work, f"keys-rotation-{size}.b64"), "w") as f:
		f.write(short + "\n" + good + "\n")
PYEOF
for size in 31 33; do
	assert_error 1 "not a 32-byte Ed25519 key" \
		"a $size-byte key before a good one refuses the trust file for its length" \
		-- "$VERIFY" "$d" "$WORK/keys-rotation-$size.b64" podup v5.9.2
	assert_error 1 "local release trust file is malformed" \
		"and it is reported as our trust file, not as a tampered release" \
		-- "$VERIFY" "$d" "$WORK/keys-rotation-$size.b64" podup v5.9.2
done

# --- Case 18: with no tag given the binding is skipped, which is why the ------
#             workflow passes --require-tag.
#
# tests/publication/publish/publish-workflow-verify-debs.test.sh runs the
# workflow step with no tag recorded; this case only pins the script's own
# contract so the two cannot drift apart silently.
assert 0 "no expected tag means the binding is not applied" \
	-- "$VERIFY" "$WORK/case16" "$WORK/key.b64" podup

# --- Case 18b: --require-tag makes the binding mandatory. ----------------------
#             An empty tag is how a publish loses the binding without anything
# saying so, so with the flag it is refused by the verifier itself. The same
# bytes are admitted with the flag and their own tag, so the refusal belongs to
# the empty tag and not to the flag, and with a wrong tag the version binding
# still fires under the flag.
assert_error 1 "but the expected tag is empty" \
	"with --require-tag an empty tag is refused" \
	-- "$VERIFY" --require-tag "$WORK/case16" "$WORK/key.b64" podup ""
assert_error 1 "but the expected tag is empty" \
	"with --require-tag an absent tag is refused" \
	-- "$VERIFY" --require-tag "$WORK/case16" "$WORK/key.b64" podup
assert 0 "with --require-tag the package is admitted under its own tag" \
	-- "$VERIFY" --require-tag "$WORK/case16" "$WORK/key.b64" podup v5.4.0
assert_error 1 "version mismatch" \
	"with --require-tag a package from another release is still refused for its version" \
	-- "$VERIFY" --require-tag "$WORK/case16" "$WORK/key.b64" podup v5.9.2

# --- Case 19: an amd64 .deb attached under an arm64 asset name is refused ---
#             because the filename is chosen by whoever uploads the asset
# and the control Architecture field is the only thing inside the signed
# bytes. A release can attach the same signed amd64 .deb twice, once under
# the `_amd64.deb` name and once under the `_arm64.deb` name; without this
# check the gate admits both and arm64 users get no package.
#
# Both checks share one script invocation so the second assertion is on the
# SAME output as the first; running the script twice and asserting on each
# invocation separately would also pass if the gate only ever printed one
# of the two architectures, which is the gap this pair closes.
d="$WORK/case19"; mkdir -p "$d"
deb="$(make_deb arch_mismatch podup)"; cp "$deb" "$d/podup_1.0.0_amd64.deb"
cp "$deb" "$d/podup_1.0.0_arm64.deb"
sign "$d/podup_1.0.0_amd64.deb"
sign "$d/podup_1.0.0_arm64.deb"
rc=0
out="$("$VERIFY" "$d" "$WORK/key.b64" podup 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "architecture mismatch"; then
	echo "ok   - an amd64 package under an arm64 asset name is refused (exit $rc)"
	pass=$((pass + 1))
else
	echo "FAIL - an amd64 package under an arm64 asset name is refused (exit $rc: $out)"
	fail=$((fail + 1))
fi
if printf '%s' "$out" | grep -qF "named for arm64" && printf '%s' "$out" | grep -qF "says amd64"; then
	echo "ok   - and the refusal names both architectures"
	pass=$((pass + 1))
else
	echo "FAIL - and the refusal names both architectures ($out)"
	fail=$((fail + 1))
fi

# --- Case 20: a package whose control Architecture matches its filename -----
#             is admitted. The opposite of case 19: this is what the gate
# must still let through so the negative case above is not satisfied by a
# gate that refused everything carrying an architecture in its name.
d="$WORK/case20"; mkdir -p "$d"
deb="$(make_deb arch_match podup 1.0 arm64)"; cp "$deb" "$d/podup_1.0.0_arm64.deb"
sign "$d/podup_1.0.0_arm64.deb"
assert 0 "a package whose control architecture matches its name passes" \
	-- "$VERIFY" "$d" "$WORK/key.b64" podup

# --- Case 21: an Architecture: all package named _all.deb is admitted -------
#             and bound to its release. epistle-panel ships one such package
# for every architecture, so the filename says `all` and so does the signed
# control field. The gate has to read that as a match, not as an unknown one.
d="$WORK/case21"; mkdir -p "$d"
deb="$(make_deb all_match epistle-panel 0.1.0 all)"; cp "$deb" "$d/epistle-panel_0.1.0_all.deb"
sign "$d/epistle-panel_0.1.0_all.deb"
assert 0 "an architecture-independent package named _all.deb passes with its product and tag" \
	-- "$VERIFY" "$d" "$WORK/key.b64" epistle-panel v0.1.0

# --- Case 22: a signed amd64 package attached under the _all.deb name -------
#             is refused. The name is set by whoever uploads the asset, so
# without the control-field comparison an arch-specific binary could be served
# to every architecture as if it were architecture-independent.
d="$WORK/case22"; mkdir -p "$d"
deb="$(make_deb all_mismatch epistle-panel 0.1.0 amd64)"; cp "$deb" "$d/epistle-panel_0.1.0_all.deb"
sign "$d/epistle-panel_0.1.0_all.deb"
rc=0
out="$("$VERIFY" "$d" "$WORK/key.b64" epistle-panel v0.1.0 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "architecture mismatch: epistle-panel_0.1.0_all.deb is named for all but its control field says amd64"; then
	echo "ok   - an amd64 package under the _all.deb name is refused, naming both"
	pass=$((pass + 1))
else
	echo "FAIL - an amd64 package under the _all.deb name is refused, naming both (rc=$rc: $out)"
	fail=$((fail + 1))
fi

# --- Case 18c: options are parsed as options. ---------------------------------
#             --require-tag anywhere but first used to be read as a path, and
# the refusal blamed the key file; an unknown option was read as the package
# directory. Both are refused by name now, and two copies of the flag are one.
assert_error 2 "comes after a positional argument" \
	"--require-tag after a positional argument is refused as misplaced" \
	-- "$VERIFY" "$WORK/case16" --require-tag "$WORK/key.b64" podup v5.4.0
assert_error 2 "unknown option --require-tags" "an unknown option is refused by name" \
	-- "$VERIFY" --require-tags "$WORK/case16" "$WORK/key.b64" podup v5.4.0
assert 0 "the flag given twice is the flag" \
	-- "$VERIFY" --require-tag --require-tag "$WORK/case16" "$WORK/key.b64" podup v5.4.0
assert_error 1 "but the expected tag is empty" "and given twice it still refuses an empty tag" \
	-- "$VERIFY" --require-tag --require-tag "$WORK/case16" "$WORK/key.b64" podup ""

# --- Case 23: nothing opens a package before its signature verified. ---------
#             dpkg-deb parses the archive, and every byte of a downloaded .deb
# is chosen by whoever can attach a release asset, in a job that later holds the
# archive signing key. A dpkg-deb on PATH that leaves a mark when it is called
# shows whether the verifier opened the package: with an invalid signature it
# must not have, and with a valid one it must have, so the mark is shown to be
# reachable and its absence to mean something.
mkdir -p "$WORK/spy"
cat > "$WORK/spy/dpkg-deb" <<SPY
#!/bin/sh
: > "$WORK/spy/opened"
exec $(command -v dpkg-deb) "\$@"
SPY
chmod +x "$WORK/spy/dpkg-deb"
d="$WORK/case23"; mkdir -p "$d"
deb="$(make_deb unopened podup 1.0.0)"; cp "$deb" "$d/podup_1.0.0_amd64.deb"
head -c 64 /dev/zero > "$d/podup_1.0.0_amd64.deb.sig"
rm -f "$WORK/spy/opened"
assert_error 1 "invalid signature for" "a package with an invalid signature is refused for its signature" \
	-- env PATH="$WORK/spy:$PATH" "$VERIFY" "$d" "$WORK/key.b64" podup v1.0.0
if [ -e "$WORK/spy/opened" ]; then
	echo "FAIL - and dpkg-deb was never called on it (it was)"; fail=$((fail + 1))
else
	echo "ok   - and dpkg-deb was never called on it"; pass=$((pass + 1))
fi
sign "$d/podup_1.0.0_amd64.deb"
rm -f "$WORK/spy/opened"
assert 0 "the same package with a valid signature is admitted" \
	-- env PATH="$WORK/spy:$PATH" "$VERIFY" "$d" "$WORK/key.b64" podup v1.0.0
if [ -e "$WORK/spy/opened" ]; then
	echo "ok   - and only then is it opened with dpkg-deb"; pass=$((pass + 1))
else
	echo "FAIL - and only then is it opened with dpkg-deb (the spy was not reached)"; fail=$((fail + 1))
fi

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
