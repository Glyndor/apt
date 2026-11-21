#!/usr/bin/env bash
#
# The hybrid release signature in scripts/verify/verify-debs.sh, verified for
# real: an Ed25519 signature and an ML-DSA-65 one over the same .deb, both
# required to pass. The checks that need no ML-DSA library are in
# tests/verify/verify-debs-hybrid.test.sh.
#
# The keys are made here, at run time, and one fixed vector is checked as well:
# tests/fixtures/verify-debs/mldsa65/ holds a public key, a .deb and its ML-DSA-65
# signature made with OpenSSL 3.5.5 (`openssl genpkey -algorithm ML-DSA-65`,
# `openssl pkeyutl -sign -rawin`). A verifier that agrees only with itself
# passes the generated cases and fails that one.
#
# This suite needs cryptography 50.0.2 or later, which the Ubuntu runner's
# python3-cryptography is not. CI runs it in a virtual environment built from
# scripts/verify/verify-debs-requirements.txt. Without the library it fails and
# says so: a suite that could not run is not a pass.
#
# Requires: python3 with cryptography >= 50.0.2, dpkg-deb.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-debs.sh"
VECTOR="$HERE/tests/fixtures/verify-debs/mldsa65"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! python3 -I -c 'from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey' 2>/dev/null; then
	echo "FAIL - $(command -v python3) has no cryptography with ML-DSA; install scripts/verify/verify-debs-requirements.txt into a virtual environment and put it first on PATH"
	echo "passed 0, failed 1"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" 0 1
	exit 1
fi

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

# One Ed25519 key and two ML-DSA-65 keys, as seeds, and the public key files:
# pq-a.b64 and pq-b.b64 hold one key each, pq-ab.b64 both.
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
w = sys.argv[1]
raw = s.Encoding.Raw
ed = Ed25519PrivateKey.generate()
open(os.path.join(w, "ed.priv"), "wb").write(ed.private_bytes(raw, s.PrivateFormat.Raw, s.NoEncryption()))
open(os.path.join(w, "ed.b64"), "w").write(base64.b64encode(ed.public_key().public_bytes(raw, s.PublicFormat.Raw)).decode() + "\n")
pub = {}
for name in ("a", "b"):
	seed = os.urandom(32)
	open(os.path.join(w, "pq-%s.seed" % name), "wb").write(seed)
	key = MLDSA65PrivateKey.from_seed_bytes(seed).public_key().public_bytes(raw, s.PublicFormat.Raw)
	pub[name] = base64.b64encode(key).decode()
	open(os.path.join(w, "pq-%s.b64" % name), "w").write(pub[name] + "\n")
open(os.path.join(w, "pq-ab.b64"), "w").write("# rotation overlap\n" + pub["a"] + "\n" + pub["b"] + "\n")
PY
printf '# none\n' > "$WORK/required-none"
printf 'podup\n' > "$WORK/required-podup"

# sign <file> ed|a|b: writes <file>.sig (Ed25519) or <file>.mldsa65.sig (key a or b).
sign() {
	python3 -I - "$WORK" "$1" "$2" <<'PY'
import os, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
w, path, who = sys.argv[1:4]
data = open(path, "rb").read()
if who == "ed":
	key = Ed25519PrivateKey.from_private_bytes(open(os.path.join(w, "ed.priv"), "rb").read())
	open(path + ".sig", "wb").write(key.sign(data))
else:
	key = MLDSA65PrivateKey.from_seed_bytes(open(os.path.join(w, "pq-%s.seed" % who), "rb").read())
	open(path + ".mldsa65.sig", "wb").write(key.sign(data))
PY
}

# make_case <dir> <version> -> <dir>/podup_<version>_amd64.deb signed by Ed25519.
make_case() {
	local d="$1" ver="$2" root
	root="$WORK/root-$ver"
	mkdir -p "$d" "$root/DEBIAN"
	printf 'Package: podup\nVersion: %s\nArchitecture: amd64\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture\n' \
		"$ver" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$d/podup_${ver}_amd64.deb" >/dev/null
	sign "$d/podup_${ver}_amd64.deb" ed
	echo "$d/podup_${ver}_amd64.deb"
}

# --- row 1: both signatures valid -------------------------------------------
d="$WORK/row1"; deb="$(make_case "$d" 1.0)"; sign "$deb" a
assert_error 0 "verified podup_1.0_amd64.deb" "both signatures valid, product not required: admitted" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-none"
assert_error 0 "verified podup_1.0_amd64.deb" "both signatures valid, product required: admitted" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-podup"

# --- row 4: the second signature present and bad ------------------------------
assert_error 1 "invalid ML-DSA-65 signature for podup_1.0_amd64.deb" \
	"a second signature made by a key that is not configured is refused" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-b.b64" "$WORK/required-none"
d="$WORK/garbage"; deb="$(make_case "$d" 1.0)"
head -c 3309 /dev/urandom > "$deb.mldsa65.sig"
assert_error 1 "invalid ML-DSA-65 signature for podup_1.0_amd64.deb" \
	"a second signature of the right length that does not verify is refused" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-none"

# A valid signature one byte short or long is refused for its length, before
# the cryptographic check, so the reason is the length and not a library error.
d="$WORK/length"; deb="$(make_case "$d" 1.0)"; sign "$deb" a
head -c 3308 "$deb.mldsa65.sig" > "$WORK/short" && mv "$WORK/short" "$deb.mldsa65.sig"
assert_error 1 "expected exactly 3309" "a valid second signature cut to 3308 bytes is refused for its length" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-none"
sign "$deb" a; printf 'x' >> "$deb.mldsa65.sig"
assert_error 1 "expected exactly 3309" "a valid second signature with one byte appended is refused for its length" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-none"

# --- two keys configured: either one may have signed (rotation overlap) -------
d="$WORK/rotation"; deb="$(make_case "$d" 1.0)"; sign "$deb" b
assert_error 0 "verified podup_1.0_amd64.deb" "a signature by the second of two configured keys is admitted" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-ab.b64" "$WORK/required-podup"
assert_error 1 "invalid ML-DSA-65 signature" "and the same signature is refused when only the first key is configured" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-podup"

# --- a valid second signature of ANOTHER asset --------------------------------
# Both releases are genuine and both signatures verify for their own bytes.
# Swapping the sidecars must fail: the signature binds the bytes, not a name.
d1="$WORK/swap1"; deb1="$(make_case "$d1" 1.0)"; sign "$deb1" a
d2="$WORK/swap2"; deb2="$(make_case "$d2" 2.0)"; sign "$deb2" a
cp "$deb2.mldsa65.sig" "$deb1.mldsa65.sig"
assert_error 1 "invalid ML-DSA-65 signature for podup_1.0_amd64.deb" \
	"a valid second signature of another .deb is refused" \
	-- "$VERIFY" "$d1" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-none"

# --- required product, valid second signature, invalid first one ---------------
d="$WORK/edbad"; deb="$(make_case "$d" 1.0)"; sign "$deb" a
head -c 64 /dev/zero > "$deb.sig"
assert_error 1 "invalid signature for podup_1.0_amd64.deb; release may be tampered" \
	"a valid second signature does not rescue an invalid Ed25519 one" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" podup v1.0 "$WORK/pq-a.b64" "$WORK/required-podup"

# --- the fixed vector, made by another implementation -------------------------
d="$WORK/vector"; mkdir -p "$d"
deb="$d/vector_1.0_amd64.deb"
base64 -d "$VECTOR/vector_1.0_amd64.deb.b64" > "$deb"
base64 -d "$VECTOR/vector_1.0_amd64.deb.mldsa65.sig.b64" > "$deb.mldsa65.sig"
sign "$deb" ed
assert_error 0 "verified vector_1.0_amd64.deb" "the OpenSSL-made ML-DSA-65 vector verifies" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" vector v1.0 "$VECTOR/vector.mldsa65.b64" "$WORK/required-none"
python3 -I - "$deb.mldsa65.sig" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
b[1000] ^= 0x01
open(p, "wb").write(bytes(b))
PY
assert_error 1 "invalid ML-DSA-65 signature for vector_1.0_amd64.deb" "and with one bit of its signature changed it does not" \
	-- "$VERIFY" "$d" "$WORK/ed.b64" vector v1.0 "$VECTOR/vector.mldsa65.b64" "$WORK/required-none"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
