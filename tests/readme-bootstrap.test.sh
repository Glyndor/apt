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
script_fpr="$(grep -o 'GLYNDOR_APT_FPR:-[0-9A-F]\{40\}' scripts/install-template.sh \
	| head -1 | sed 's/.*:-//')"
readme_fpr="$(grep -o '[0-9A-F ]\{50,\}' "$README" | head -1 | tr -d ' ')"
check "the README fingerprint matches the one the installer enforces" \
	"$script_fpr" "$readme_fpr"

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
