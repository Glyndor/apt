#!/usr/bin/env bash
#
# scripts/verify/verify-debs.sh reads the Package, the Version and the Architecture
# control fields of every package it admits, and refuses one whose field dpkg-deb
# cannot read: a package whose version cannot be bound to its release, or whose
# architecture cannot be bound to its name, must not be admitted unclassified.
# verify-debs.test.sh covers the Package field with a file that is not a package at
# all. Such a file fails on the first field it is asked for, so it never reaches the
# other two; here a dpkg-deb on PATH fails for one field only and answers the rest, so
# the refusal that fires is the one of the field the case names.
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

# A signed podup 1.0.0 package for amd64, and the key that verifies it.
d="$WORK/case"
root="$WORK/root"
mkdir -p "$d" "$root/DEBIAN"
printf 'Package: podup\nVersion: 1.0.0\nArchitecture: amd64\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture\n' \
	> "$root/DEBIAN/control"
dpkg-deb --root-owner-group --build "$root" "$d/podup_1.0.0_amd64.deb" >/dev/null
python3 -I - "$WORK/key.b64" "$d/podup_1.0.0_amd64.deb" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.generate()
open(sys.argv[1], "w").write(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode() + "\n")
open(sys.argv[2] + ".sig", "wb").write(k.sign(open(sys.argv[2], "rb").read()))
PY

# dpkg-deb that refuses to print the field named by FAIL_FIELD and runs as usual otherwise.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/dpkg-deb" <<STUB
#!/bin/sh
if [ "\$1" = -f ] && [ "\$3" = "\${FAIL_FIELD:-}" ]; then
	echo "dpkg-deb: the control field \$3 cannot be read" >&2
	exit 2
fi
exec $(command -v dpkg-deb) "\$@"
STUB
chmod 755 "$WORK/stub/dpkg-deb"
verify() { env PATH="$WORK/stub:$PATH" FAIL_FIELD="$1" "$VERIFY" "$d" "$WORK/key.b64" podup v1.0.0; }

assert_error 0 "verified podup_1.0.0_amd64.deb" "with every field readable the package is admitted" -- verify ""
assert_error 1 "cannot read the Package control field" "a Package field that cannot be read is refused for it" -- verify Package
assert_error 1 "cannot read the Version control field" "a Version field that cannot be read is refused for it" -- verify Version
assert_error 1 "cannot read the Architecture control field" "an Architecture field that cannot be read is refused for it" -- verify Architecture

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
