#!/usr/bin/env bash
#
# The hybrid release signature in scripts/verify/verify-debs.sh, the half that
# needs no ML-DSA library: which second signature is required, which one is
# refused before any cryptography runs, and the refusal when the library cannot
# verify one. The cases that verify a real ML-DSA-65 signature are in
# tests/verify/verify-debs-mldsa.test.sh, which needs cryptography 50.0.2.
#
# Every case asserts the reason of a refusal, not only the exit status, and the
# ML-DSA-65 fixtures are valid in every respect except the one under test: a
# public key is 1952 bytes of valid base64, a signature is 3309 bytes, so the
# check that refuses is the one the case names.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-debs.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+rw "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0
fail=0

# assert_error <expected-exit> <needle> <description> -- <command...>
# The needle is required in the combined output; an empty needle accepts any.
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

# refute <needle> <description> -- <command...>: the output must NOT carry it.
refute() {
	local needle="$1" desc="$2"
	shift 3
	local out
	out="$("$@" 2>&1)" || true
	if printf '%s' "$out" | grep -qF -- "$needle"; then
		echo "FAIL - $desc (found '$needle': $out)"
		fail=$((fail + 1))
	else
		echo "ok   - $desc"
		pass=$((pass + 1))
	fi
}

# make_case <dir> <package> -> builds <dir>/<package>_1.0_amd64.deb with a valid
# Ed25519 signature and prints its path.
make_case() {
	local d="$1" pkg="$2" root
	root="$WORK/root-$pkg"
	mkdir -p "$d" "$root/DEBIAN"
	printf 'Package: %s\nVersion: 1.0\nArchitecture: amd64\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture\n' \
		"$pkg" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$d/${pkg}_1.0_amd64.deb" >/dev/null
	python3 -I - "$WORK/priv.b64" "$d/${pkg}_1.0_amd64.deb" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(sys.argv[1]).read()))
open(sys.argv[2] + ".sig", "wb").write(k.sign(open(sys.argv[2], "rb").read()))
PY
	echo "$d/${pkg}_1.0_amd64.deb"
}

# An Ed25519 key, and a stand-in ML-DSA-65 public key: 1952 random bytes are
# a well-formed key file entry, which is all that the checks here read.
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
w = sys.argv[1]
k = Ed25519PrivateKey.generate()
open(os.path.join(w, "priv.b64"), "w").write(base64.b64encode(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())).decode())
open(os.path.join(w, "ed.b64"), "w").write(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode() + "\n")
open(os.path.join(w, "pq.b64"), "w").write("# a key\n" + base64.b64encode(os.urandom(1952)).decode() + "\n")
open(os.path.join(w, "pq-short.b64"), "w").write(base64.b64encode(os.urandom(1951)).decode() + "\n")
PY
printf '# no key\n' > "$WORK/pq-none.b64"
printf '# none\n' > "$WORK/required-none"
printf '# the products\n  podup  \n\nepistle\n' > "$WORK/required-podup"
printf 'epistle\n' > "$WORK/required-other"
key="$(grep -v '^#' "$WORK/pq.b64")"
printf '%s!%s\n' "${key:0:40}" "${key:40}" > "$WORK/pq-stray.b64"

# --- row 2: no second signature, product not required: admitted, as before ----
d="$WORK/row2"; deb="$(make_case "$d" podup)"
assert_error 0 "verified podup_1.0_amd64.deb" "no second signature and the product not required is admitted" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"
assert_error 0 "verified podup_1.0_amd64.deb" "and so it is with no key file and no required file at all" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/absent.b64" "$WORK/absent-required"
assert_error 0 "verified podup_1.0_amd64.deb" "and with another product required" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-other"

# The committed defaults are what publish.yml uses: today no key and no product
# required, so a release without a second signature is admitted exactly as before.
assert_error 0 "verified podup_1.0_amd64.deb" "the committed key and required files admit a release without one" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup

# --- row 3: no second signature, product required: refused for that -----------
assert_error 1 "no ML-DSA-65 signature" "a required product without its second signature is refused for it" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-podup"
assert_error 1 "podup requires the hybrid release signature" "and the refusal names the product" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq-none.b64" "$WORK/required-podup"

# The list is read from the control Package field, inside the signed bytes, so
# an asset renamed out of its product's name is still required.
d="$WORK/renamed"; deb="$(make_case "$d" podup)"
mv "$deb" "$d/renamed.deb"; mv "$deb.sig" "$d/renamed.deb.sig"
assert_error 1 "no ML-DSA-65 signature" "the requirement follows the control Package, not the filename" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" "" "" "$WORK/pq.b64" "$WORK/required-podup"

# --- row 5: a second signature and no ML-DSA-65 key configured ------------------
d="$WORK/row5"; deb="$(make_case "$d" podup)"
head -c 3309 /dev/urandom > "$deb.mldsa65.sig"
assert_error 1 "no ML-DSA-65 release public key is configured" \
	"a second signature with no key configured is refused, not skipped" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq-none.b64" "$WORK/required-none"
assert_error 1 "no ML-DSA-65 release public key is configured" "and so it is with no key file" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/absent.b64" "$WORK/required-none"
assert_error 1 "no ML-DSA-65 release public key is configured" "and with the committed key file, which holds none" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup

# --- row 6: the Ed25519 signature decides first ------------------------------
d="$WORK/row6"; deb="$(make_case "$d" podup)"
head -c 3309 /dev/urandom > "$deb.mldsa65.sig"
head -c 64 /dev/zero > "$deb.sig"
assert_error 1 "invalid signature for podup_1.0_amd64.deb" "an invalid Ed25519 signature is refused beside a second one" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-podup"
refute "ML-DSA-65" "and the refusal is the Ed25519 one, checked before the second" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-podup"
rm "$deb.sig"
assert_error 1 "no signature" "a missing Ed25519 signature is refused beside a second one" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-podup"

# --- the second signature's length, before any cryptography ------------------
d="$WORK/length"; deb="$(make_case "$d" podup)"
head -c 3308 /dev/urandom > "$deb.mldsa65.sig"
assert_error 1 "expected exactly 3309" "a 3308-byte second signature is refused for its length" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"
head -c 3310 /dev/urandom > "$deb.mldsa65.sig"
assert_error 1 "expected exactly 3309" "a 3310-byte second signature is refused for its length" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"
head -c 5000 /dev/urandom > "$deb.mldsa65.sig"
assert_error 1 "over 4096 bytes" "a second signature over the read cap is refused by the bounded read" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"
rm "$deb.mldsa65.sig"; mkdir "$deb.mldsa65.sig"
assert_error 1 "cannot read the ML-DSA-65 signature file" "a second signature that cannot be read is refused as unreadable" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"

# --- our own ML-DSA-65 key file, checked before any package -------------------
d="$WORK/anchor"; deb="$(make_case "$d" podup)"
assert_error 1 "local ML-DSA-65 release trust file" "a key with a character outside base64 is refused as our malformed file" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq-stray.b64" "$WORK/required-none"
assert_error 1 "not a 1952-byte ML-DSA-65 public key" "a 1951-byte key is refused for its length" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq-short.b64" "$WORK/required-none"
refute "release may be tampered" "and neither is reported as a tampered release" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq-short.b64" "$WORK/required-none"

# --- a file that exists and cannot be read ---------------------------------------
cp "$WORK/required-podup" "$WORK/required-locked"; chmod 000 "$WORK/required-locked"
if [ -r "$WORK/required-locked" ]; then
	# Root reads a mode-000 file, so the case cannot be built there. Say so
	# rather than count a pass.
	echo "not run - an unreadable required file (running as root, the file stays readable)"
else
	assert_error 1 "cannot read the required-products file" "an unreadable required file is an error, not an empty list" \
		-- "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-locked"
fi

# --- the library cannot verify ML-DSA: refused and said ------------------------
# The runner's python3-cryptography has no ML-DSA. The blocker below makes that
# true on any machine, so the case does not depend on which version is installed.
mkdir -p "$WORK/no-mldsa"
cat > "$WORK/no-mldsa/sitecustomize.py" <<'PY'
import sys
class Block:
    def find_spec(self, name, path=None, target=None):
        if name == "cryptography.hazmat.primitives.asymmetric.mldsa":
            raise ModuleNotFoundError("No module named " + repr(name))
sys.meta_path.insert(0, Block())
PY
d="$WORK/nolib"; deb="$(make_case "$d" podup)"
head -c 3309 /dev/urandom > "$deb.mldsa65.sig"
assert_error 1 "the installed cryptography has no ML-DSA support" \
	"a second signature the library cannot verify is refused, and the reason is the library" \
	-- env PYTHONPATH="$WORK/no-mldsa" "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"
rm "$deb.mldsa65.sig"
assert_error 0 "verified podup_1.0_amd64.deb" "and without a second signature the same machine admits the release" \
	-- env PYTHONPATH="$WORK/no-mldsa" "$VERIFY" "$d" "$WORK/ed.b64" podup "" "$WORK/pq.b64" "$WORK/required-none"

# --- the committed files -----------------------------------------------------
# A product required while no key is configured refuses every release of it,
# with or without the second signature, so the rollout order is pinned here.
committed() { grep -vcE '^[[:space:]]*(#|$)' "$HERE/keyring/$1" || true; }
if [ -f "$HERE/keyring/glyndor-release-mldsa65.b64" ] && [ -f "$HERE/keyring/pq-required-products" ]; then
	echo "ok   - the ML-DSA-65 key file and the required file are committed"; pass=$((pass + 1))
else
	echo "FAIL - the ML-DSA-65 key file and the required file are committed"; fail=$((fail + 1))
fi
if [ "$(committed pq-required-products)" -eq 0 ] || [ "$(committed glyndor-release-mldsa65.b64)" -ge 1 ]; then
	echo "ok   - no product is required before an ML-DSA-65 key is committed"; pass=$((pass + 1))
else
	echo "FAIL - a product is required while keyring/glyndor-release-mldsa65.b64 holds no key"; fail=$((fail + 1))
fi

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
