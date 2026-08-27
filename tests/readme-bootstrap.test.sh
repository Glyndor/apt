#!/usr/bin/env bash
#
# The README is the second channel. scripts/build-index-page.sh sends readers
# here to compare a fingerprint against something apt.glyndor.net does not
# serve, and podup/docs/debian-packaging.md links here for the same reason, so
# two properties of this file are load-bearing for repositories that cannot see
# it change:
#
#   1. The bootstrap checks the key before `dpkg -i` executes anything from the
#      package. Reordering these three commands is the whole vulnerability.
#   2. The `verify-the-signing-key` anchor keeps existing. Renaming that
#      heading does not break a build and does not 404 -- GitHub drops the
#      reader at the top of the page instead, which looks like it worked.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/.." || exit 1
README="README.md"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

line_of() { grep -n -- "$1" "$README" | head -1 | cut -d: -f1; }

once() { grep -c -- "$1" "$README"; }
for lit in 'dpkg-deb -x glyndor-archive-keyring.deb' \
	'sudo dpkg -i glyndor-archive-keyring.deb'; do
	check "'$lit' appears exactly once, so the ordering checks cannot pick the wrong copy" \
		"1" "$(once "$lit")"
done

extract_at="$(line_of 'dpkg-deb -x glyndor-archive-keyring.deb')"
fpr_at="$(line_of '9ADF 04EA 8C31 39CD B673  03CF A670 5C2E A153 F3D6')"
install_at="$(line_of 'sudo dpkg -i glyndor-archive-keyring.deb')"

check "the README unpacks the keyring without installing it" "1" \
	"$([ -n "$extract_at" ] && echo 1 || echo 0)"
check "the README publishes the archive key fingerprint" "1" \
	"$([ -n "$fpr_at" ] && echo 1 || echo 0)"
check "the README still shows the install step" "1" \
	"$([ -n "$install_at" ] && echo 1 || echo 0)"
check "unpacking comes before the fingerprint" "1" \
	"$([ -n "$extract_at" ] && [ -n "$fpr_at" ] && [ "$extract_at" -lt "$fpr_at" ] && echo 1 || echo 0)"
check "the fingerprint comes before dpkg -i" "1" \
	"$([ -n "$fpr_at" ] && [ -n "$install_at" ] && [ "$fpr_at" -lt "$install_at" ] && echo 1 || echo 0)"

# The fingerprint here must be the one the installer enforces, or the manual
# path and the scripted path disagree about which key is the right one.
# The installer takes the fingerprint from the environment and falls back to a
# baked-in default; the default is the value that ships, so that is the one to
# compare against.
# EVERY fingerprint the installer accepts has to be published here, not just the
# first. Since apt#141 the installer admits a keyring only if every key in it is
# one it was told to expect, so during a rotation GLYNDOR_APT_FPR carries two --
# and a reader checking a keyring that ships both needs both values from this
# page. Comparing head -1 against head -1 would pass a rotation in which the
# incoming fingerprint was never published, which is the exact state that makes
# fresh installs refuse the new keyring.
script_fprs="$(grep -oE 'GLYNDOR_APT_FPR:-[0-9A-F,]+' scripts/install-template.sh \
	| head -1 | sed 's/.*:-//' | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort)"
readme_fprs="$(grep -oE '[0-9A-F]{4}( {1,2}[0-9A-F]{4}){9}' "$README" \
	| tr -d ' ' | LC_ALL=C sort -u)"

check "the installer's default names at least one fingerprint" "1" \
	"$([ -n "$script_fprs" ] && echo 1 || echo 0)"

# Set difference, not equality: the README may publish a fingerprint the
# installer's default does not yet name -- that is phase one of a rotation, and
# publishing first is what the order requires. The reverse is the failure.
unpublished="$(comm -23 <(printf '%s\n' "$script_fprs") <(printf '%s\n' "$readme_fprs"))"
check "every fingerprint the installer accepts is published here" "" "$unpublished"

# The fingerprint carries two spaces between the fifth and sixth groups, which
# is how `gpg --show-keys` prints it. Markdown collapses runs of whitespace
# everywhere except inside a fenced block, so publishing it as prose or in a
# table renders a value that does not match what the reader's own gpg printed,
# and they conclude the key is wrong. Measured: 2 spaces fenced, 1 either other
# way. Nothing else in the file catches this -- the checks above read the raw
# bytes, where all three spellings look identical.
# Track the fence state rather than counting one marker's parity: markdown has
# two fence spellings and a ``` does not close a ~~~. Counting backticks alone
# called a ~~~-fenced fingerprint unfenced -- measured as a false positive,
# 2 spaces surviving in the browser while the check failed.
inside="$(awk -v n="$fpr_at" '
	NR >= n { exit }
	{
		if (open == "") { if (/^```/) open = "b"; else if (/^~~~/) open = "t" }
		else if (open == "b" && /^```/) open = ""
		else if (open == "t" && /^~~~/) open = ""
	}
	END { print (open == "") ? 0 : 1 }' "$README")"
check "the fingerprint sits inside a fenced block, so its two spaces survive" "1" \
	"$inside"

# Anchors are generated from heading text: lowercased, spaces to hyphens.
# Derive them rather than grepping for the literal string, so a heading that
# renders to the right anchor by another spelling still counts.
anchors="$(grep '^#\{2,\} ' "$README" \
	| sed 's/^#* //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -d '`.,')"
check "the anchor other repositories link to still exists" "1" \
	"$(echo "$anchors" | grep -cx 'verify-the-signing-key')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
