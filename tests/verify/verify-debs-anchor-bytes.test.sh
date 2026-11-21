#!/usr/bin/env bash
#
# The files verify-debs.sh reads from keyring/ are the trust anchor: the two
# release public keys and the list of products that require the second
# signature. The script strips every blank from a line before it reads it, so a
# copy of a file with CRLF line ends read as the same keys, and a carriage
# return inside a comment line read as none, while another reader of the same
# file (Glyndor/podman, which publishes the packages) refuses either. The two
# readers must agree, so a file with any byte other than printable ASCII and a
# line feed is refused whole, before a key is read, and nothing is admitted.
#
# Each of the six bytes below is planted in each of the three files, and each
# refusal is asserted by its message and by the absence of "verified", so a
# package is not admitted on the way. The same file without the byte is
# admitted, which is what makes the refusal the byte's and not the fixture's.
# The committed files are asserted to hold no such byte, and the real
# keyring/ is read by the script with its defaults.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-debs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# A signed package, an Ed25519 key file and a stand-in ML-DSA-65 key file, as
# the hybrid suite builds them.
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
w = sys.argv[1]
k = Ed25519PrivateKey.generate()
open(os.path.join(w, "priv.b64"), "w").write(base64.b64encode(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())).decode())
open(os.path.join(w, "ed.b64"), "w").write("# a key\n" + base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode() + "\n")
open(os.path.join(w, "pq.b64"), "w").write("# a key\n" + base64.b64encode(os.urandom(1952)).decode() + "\n")
PY
printf '# none\n' > "$WORK/required.txt"
root="$WORK/root"; mkdir -p "$root/DEBIAN" "$WORK/debs"
printf 'Package: podup\nVersion: 1.0\nArchitecture: amd64\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture\n' > "$root/DEBIAN/control"
dpkg-deb --root-owner-group --build "$root" "$WORK/debs/podup_1.0_amd64.deb" >/dev/null
python3 -I - "$WORK/priv.b64" "$WORK/debs/podup_1.0_amd64.deb" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(sys.argv[1]).read()))
open(sys.argv[2] + ".sig", "wb").write(k.sign(open(sys.argv[2], "rb").read()))
PY

run() { # <ed file> <pq file> <required file>: what it said is in $OUT, the status in $RC
	RC=0; OUT="$("$VERIFY" "$WORK/debs" "$1" podup "" "$2" "$3" 2>&1)" || RC=$?
}
said() { printf '%s' "$1" | grep -cF -- "$2"; }

run "$WORK/ed.b64" "$WORK/pq.b64" "$WORK/required.txt"
check "the three files, clean, admit the package" "0" "$RC"
check "and say so" "1" "$(said "$OUT" 'verified podup_1.0_amd64.deb')"

# plant <file kind> <what> -> writes the variant of that file into $WORK/planted
plant() {
	local src
	case "$1" in ed) src=ed.b64 ;; pq) src=pq.b64 ;; required) src=required.txt ;; esac
	case "$2" in
	CRLF)    sed 's/$/\r/' "$WORK/$src" > "$WORK/planted" ;;
	CRinside) { printf '# a comment\r with a carriage return\n'; cat "$WORK/$src"; } > "$WORK/planted" ;;
	BOM)     { printf '\xef\xbb\xbf'; cat "$WORK/$src"; } > "$WORK/planted" ;;
	tab)     { printf '# a\tcomment\n'; cat "$WORK/$src"; } > "$WORK/planted" ;;
	NUL)     { printf '# a\0comment\n'; cat "$WORK/$src"; } > "$WORK/planted" ;;
	0x80)    { printf '# a \x80 comment\n'; cat "$WORK/$src"; } > "$WORK/planted" ;;
	esac
}
run_planted() { # <file kind>
	case "$1" in
	ed)       run "$WORK/planted" "$WORK/pq.b64" "$WORK/required.txt" ;;
	pq)       run "$WORK/ed.b64" "$WORK/planted" "$WORK/required.txt" ;;
	required) run "$WORK/ed.b64" "$WORK/pq.b64" "$WORK/planted" ;;
	esac
}

for kind in ed pq required; do
	for what in CRLF CRinside BOM tab NUL 0x80; do
		plant "$kind" "$what"
		cmp -s "$WORK/planted" "$WORK/$(case $kind in ed) echo ed.b64 ;; pq) echo pq.b64 ;; required) echo required.txt ;; esac)" \
			&& echo "SABOTAGE INERT: $kind $what left the file unchanged"
		run_planted "$kind"
		check "$kind file with $what is refused" "1" "$RC"
		check "  as a broken trust anchor, naming the file" "1" "$(said "$OUT" "$WORK/planted holds")"
		check "  before any package is admitted" "0" "$(said "$OUT" 'verified podup')"
	done
done

# A byte count that is exact: one carriage return in a one-line file.
printf '# a comment\r\n%s\n' "$(grep -v '^#' "$WORK/ed.b64")" > "$WORK/one-cr"
run "$WORK/one-cr" "$WORK/pq.b64" "$WORK/required.txt"
check "a single carriage return is counted as one byte" "1" "$(said "$OUT" 'one-cr holds 1 byte(s)')"

# The key file is read as before when it is clean, blanks and comments included:
# the rule refuses bytes, not layout.
printf '# a key, indented and spaced\n   %s  \n\n' "$(grep -v '^#' "$WORK/ed.b64")" > "$WORK/layout.b64"
run "$WORK/layout.b64" "$WORK/pq.b64" "$WORK/required.txt" >/dev/null
check "blanks and blank lines in a clean key file are still accepted" "0" "$RC"
printf '%s' "$(grep -v '^#' "$WORK/ed.b64")" > "$WORK/no-newline.b64"
run "$WORK/no-newline.b64" "$WORK/pq.b64" "$WORK/required.txt" >/dev/null
check "and so is a last line with no line feed" "0" "$RC"

# A file that is not there is the caller's business, as it was: the ML-DSA-65
# files may be missing from a tree that predates the second signature.
run "$WORK/ed.b64" "$WORK/absent" "$WORK/absent-required" >/dev/null
check "optional files that are absent are not refused" "0" "$RC"

# The committed files, read by the script with its defaults, hold none of it.
OUT="$("$VERIFY" "$WORK/debs" "$WORK/ed.b64" podup 2>&1)"
check "the committed ML-DSA-65 and required files are not refused as trust anchors" "0" "$(said "$OUT" 'broken trust anchor')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
