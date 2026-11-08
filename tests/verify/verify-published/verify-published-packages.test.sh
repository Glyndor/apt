#!/usr/bin/env bash
#
# Tests for how scripts/verify/verify-published.sh reads a verified Packages
# file: the third link of the chain, from the signed index to the .deb files an
# apt client installs.
#
# The parser has to see EVERY stanza. Two stanzas that lost the blank line
# between them were read as one, only the last one's fields survived, and the
# first package was never fetched: a publish stayed green over a file that was
# missing from the bucket. A path made only of dots is also not a plain relative
# path, and the check that says so must say it for `.` and `..` too.
#
# The archive, the keys and the local HTTP server come from
# tests/fixtures/verify/verify-published-fixture.sh.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/fixtures/verify/verify-published-fixture.sh
. "$HERE/tests/fixtures/verify/verify-published-fixture.sh"

pass=0
fail=0

# --- Stanzas without a separator ---------------------------------------------

build_archive
assert 0 "the control: an intact archive is accepted" -- run

build_archive
# Drop every blank line, so each architecture's stanzas run into one another,
# then make the first package unreachable. A parser that keeps only the last
# stanza's fields never asks for it.
for arch in amd64 arm64; do
	sed -i '/^$/d' "$DIST/main/binary-$arch/Packages"
done
write_release "$TRUSTED_KEY"
rm "$SITE/$PODUP_POOL/podup_1.12.0_amd64.deb"
assert_error 1 "podup_1.12.0_amd64.deb" \
	"a package whose stanza lost its separator is still verified" -- run

# --- Paths made only of dots -------------------------------------------------

for bad in . .. ./x a/./b a/.; do
	build_archive
	sed -i "s|Filename: $PODUP_POOL/podup_1.12.0_amd64.deb|Filename: $bad|" \
		"$DIST/main/binary-amd64/Packages"
	write_release "$TRUSTED_KEY"
	assert_error 1 "not a plain relative path" \
		"the declared path '$bad' is rejected" -- run
done

# --- Paths with characters outside the allowlist ------------------------------
# A path is fetched as a URL, so a character the pool layout never uses (an
# equals sign, a space, a percent) is refused rather than escaped.
for bad in 'pool/main/p/podup/podup=1.12.0_amd64.deb' 'pool/main/p/a%20b.deb' 'pool/main/p/a;b.deb'; do
	build_archive
	python3 -I - "$DIST/main/binary-amd64/Packages" "$PODUP_POOL/podup_1.12.0_amd64.deb" "$bad" <<'PY'
import sys
p, old, new = sys.argv[1:]
text = open(p).read()
assert "Filename: " + old in text
open(p, "w").write(text.replace("Filename: " + old, "Filename: " + new, 1))
PY
	write_release "$TRUSTED_KEY"
	assert_error 1 "unexpected characters" \
		"the declared path '$bad' is rejected" -- run
done

# --- A stanza that lacks a field is an error, not a silent omission ----------
# A signed index with the podup stanza minus its Filename produced nothing for
# that package and exit 0, and the stanza of the keyring package was enough to
# satisfy the rule that the index lists something at all.
strip_podup_field() { # $1=field: remove it from podup's stanza in amd64
	build_archive
	python3 -I - "$DIST/main/binary-amd64/Packages" "$1" <<'PY'
import re, sys
p, field = sys.argv[1:]
text = open(p).read()
stanzas = text.split("\n\n")
out = []
for st in stanzas:
	if st.startswith("Package: podup\n"):
		st = re.sub(r"^%s:.*\n?" % field, "", st, count=1, flags=re.M)
	out.append(st)
open(p, "w").write("\n\n".join(out))
PY
	write_release "$TRUSTED_KEY"
}
for field in Filename Size SHA256; do
	strip_podup_field "$field"
	assert_error 1 "the Packages stanza for podup lacks" \
		"a podup stanza without $field is refused and names the package" -- run
done
build_archive
python3 -I - "$DIST/main/binary-amd64/Packages" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
i = text.index("Filename:")
j = text.index("\n", i)
open(p, "w").write(text[:j + 1] + text[i:j + 1] + text[j + 1:])
PY
write_release "$TRUSTED_KEY"
assert_error 1 "repeats Filename" "a stanza that repeats Filename is refused" -- run
# Control: the script with the error for a missing field replaced by nothing,
# which is what it did before. The archive without a Filename then passes.
CUT="$WORK/verify-published-cut.sh"
python3 -I - "$VERIFY" "$CUT" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = 'print "::error::the Packages stanza for " pkg " lacks Filename, Size or SHA256" > "/dev/stderr"; bad = 1'
assert old in s
open(sys.argv[2], "w").write(s.replace(old, "pkg = pkg", 1))
PY
chmod +x "$CUT"
strip_podup_field Filename
got=0; "$CUT" "$BASE" "$TRUSTED_ASC" 1 0 >/dev/null 2>&1 || got=$?
if [ "$got" -eq 0 ]; then
	echo "ok   - control: without the error, the stanza with no Filename is silently dropped"; pass=$((pass + 1))
else
	echo "FAIL - control: the cut script still refused (exit $got)"; fail=$((fail + 1))
fi

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
