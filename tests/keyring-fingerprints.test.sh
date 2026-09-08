#!/usr/bin/env bash
#
# The packaged archive key and the fingerprint the installer accepts are the
# same trust anchor -- the keyring ships inside the keyring package, and the
# installer refuses the package unless the key it ships is one it was told to
# expect. They drifted: tests/readme-bootstrap.test.sh ties the installer's
# default to the README, and scripts/build-repo.sh ties the signing secret to
# the keyring, but nothing tied the keyring to the installer's default.
#
# Committing a fresh keyring .asc without touching the installer left every
# suite green. Fresh installs then refused the package with "does not carry
# the expected fingerprint", and the only signal was the error on the wire --
# because the very test that would have caught it was not in the repository.
#
# This file is the mirror of tests/readme-bootstrap.test.sh. That test compares
# installer -> README and accepts the README leading (phase one of a rotation);
# this one compares keyring -> installer and accepts the installer leading.
# Either direction makes the same rotation legal. The failure each guards
# against is the other: an installer-accepted fingerprint never published is a
# silent README drift; a packaged fingerprint the installer does not accept
# is a silent installer drift. Same overlap, opposite edges.
#
# Only primary fingerprints count. `gpg --show-keys --with-colons` emits an
# `fpr:` line per subkey as well, and a subkey fingerprint is not something
# the installer compares against. The awk here applies the same rule the
# installer uses -- first `fpr:` after each `pub:`, never the `fpr:` that
# follows a `sub:` -- and a copy of install-template.sh, line by line, lives
# above it.
#
# Requires: gpg, coreutils.
set -euo pipefail

# The probe at the bottom re-runs this same file against a scratch tree, so
# the tree it reads is a variable rather than always the repository. Asserting
# the shape of a comparison is not asserting the comparison: running the real
# file over a planted violation is.
ROOT="${GLYNDOR_KEYRING_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1
KEYRING="keyring/glyndor-apt-key.asc"
INSTALLER="scripts/install-template.sh"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Mirrors the rule in scripts/install-template.sh (around the `keyring_fprs=`
# assignment) that picks primary fingerprints out of `gpg --show-keys
# --with-colons`. That command emits one `fpr:` line per subkey, and a
# subkey fingerprint is not something the installer compares against; what
# it compares is the primary, which is the `fpr:` line that follows a `pub:`
# line. Reading the first `fpr:` after each `pub:` is what isolates them.
primaries() { # $1=asc -> prints one primary fingerprint per line
	gpg --show-keys --with-colons "$1" 2>/dev/null \
		| awk -F: '/^pub:/{want=1;next} /^fpr:/{if(want){print $10;want=0}}'
}

keyring_fprs="$(primaries "$KEYRING")"
# Reading nothing is not the same as reading an empty keyring. Without this
# guard, `set -e` would not catch the gpg failure (its stderr was discarded)
# and the loop below would iterate zero times; the check that follows would
# compare empty against empty and report success while inspecting nothing,
# which is exactly the failure mode this whole file exists to prevent.
[ -n "$keyring_fprs" ] \
	|| { echo "could not read any primary fingerprint from $KEYRING" >&2; exit 1; }

# Same shape tests/readme-bootstrap.test.sh uses to read the installer's
# default. `DEFAULT_FPR` is that value: the parameter expansion below it falls
# back to the same variable, so there is one literal rather than two. A
# rotation pastes two values here, comma-separated, which is why the
# extraction splits on `,`.
#
# It used to read the literal out of the parameter expansion, because the
# expansion carried its own copy. That copy is what made a correct rotation
# warn on every stock install, and the case at the end of this file is what
# holds the two together now.
script_fprs="$(grep -oE '^DEFAULT_FPR="[0-9A-F,]+"' "$INSTALLER" \
	| head -1 | sed 's/^DEFAULT_FPR="//; s/"$//' | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort -u)"
[ -n "$script_fprs" ] \
	|| { echo "could not read DEFAULT_FPR from $INSTALLER" >&2; exit 1; }

# Sanity check on the keyring side. A fingerprint with the wrong shape is
# not a value the installer can accept -- the comparison above would silently
# report nothing as a miss and the suite would go green on a keyring that
# cannot work. The check is on the bytes we just read; a one-character drift
# in the .asc is the exact failure mode the rest of the file exists to
# prevent, and reporting it here is what makes a bad keyring loud.
for fpr in $keyring_fprs; do
	check "packaged primary '$fpr' is 40 hex characters" "1" \
		"$([ "${#fpr}" -eq 40 ] && printf '%s' "$fpr" | grep -qxE '[0-9A-F]{40}' && echo 1 || echo 0)"
done

# Direction: set difference in one direction only.
#
# The installer may accept a fingerprint the package does not yet carry --
# that is the overlap of a two-phase rotation, and tests/readme-bootstrap.test.sh
# already accepts the README leading. The committed keyring ships without
# the second key during phase one, and the installer already knows both.
#
# The reverse is the failure: a packaged fingerprint the installer does not
# accept means every fresh install refuses the keyring with "does not carry
# the expected fingerprint". comm -23 of (keyring primary fingerprints)
# minus (installer's accepted fingerprints) -- sorted, unique on both sides
# -- names the offenders.
not_accepted="$(comm -23 \
	<(printf '%s\n' "$keyring_fprs" | LC_ALL=C sort -u) \
	<(printf '%s\n' "$script_fprs"))"
check "every primary fingerprint in the packaged keyring is one the installer accepts" \
	"" "$not_accepted"

# --- a rotation must not make a stock install warn --------------------------
#
# The archive rotates a key by publishing a keyring that carries the old and
# the new one together, so the default becomes two fingerprints separated by a
# comma. The installer compares its default against the value in force to
# decide whether the operator replaced it, and prints "this is not the stock
# Glyndor install." when they differ.
#
# Before the two literals were folded into one, that comparison read a SECOND
# copy of the default. Editing the value in one place, which is all a rotation
# is, left the copy behind, the two never matched, and every clean install off
# the official archive spent the whole overlap window telling the operator it
# was not the official archive.
#
# So the case is the rotation edit itself: change the default on a copy of the
# installer, exactly as a maintainer would, and run the comparison with nothing
# overridden.
rot_installer="$(mktemp)"
rot_block="$(mktemp)"
trap 'rm -f "$rot_installer" "$rot_block"' EXIT

packaged_fpr="$(printf '%s' "$keyring_fprs" | head -1)"
# A second 40-hex value that is certainly not the first. Flipping the leading
# digit avoids needing a key generator to produce something key-shaped.
incoming_fpr="$(printf '%s' "$packaged_fpr" | sed 's/^./0/')"

sed "s/^DEFAULT_FPR=\"[0-9A-F,]*\"/DEFAULT_FPR=\"$packaged_fpr,$incoming_fpr\"/" \
	"$INSTALLER" > "$rot_installer"

# An edit that changed nothing would leave this case measuring the ordinary
# single-fingerprint path and reporting success over it.
if cmp -s "$INSTALLER" "$rot_installer"; then
	echo "FAIL  the rotation edit changed nothing; DEFAULT_FPR was not where this case expects it" >&2
	exit 1
fi

# The slice runs from the first assignment the comparison reads to the
# comparison itself, so whatever the installer sets in between is what the
# comparison sees. Deliberately NOT seeded with a DEFAULT_FPR of our own: the
# installer's own line is inside this range, so a value set here would be
# overwritten and the case would silently measure the stock pair instead of a
# rotation.
awk '/^DEFAULT_URL=/ { p = 1 } p; /fpr_overridden=yes/ { exit }' "$rot_installer" \
	> "$rot_block"
# shellcheck disable=SC2016  # $fpr_overridden must reach the block unexpanded;
# the sh that runs the block is what expands it, and expanding it here would
# write an empty string and make the assertions read their own setup.
printf 'printf "OVERRIDE=%%s\\n" "$fpr_overridden"\n' >> "$rot_block"

grep -q "$incoming_fpr" "$rot_block" \
	|| { echo "FAIL  the extracted comparison does not carry the rotated default" >&2; exit 1; }

rot_out="$(env -u KEYRING_URL -u GLYNDOR_APT_FPR sh "$rot_block" 2>&1)"
check "a rotation default reaches the comparison" "1" \
	"$(printf '%s' "$rot_out" | grep -c '^OVERRIDE=')"
check "and a stock install during a rotation is not called an override" "OVERRIDE=no" \
	"$(printf '%s' "$rot_out" | grep '^OVERRIDE=' | head -1)"

# The other half, or the assertion above is satisfied by a comparison that
# answers "no" to everything.
rot_out="$(KEYRING_URL=http://fork.test/x.deb GLYNDOR_APT_FPR="$incoming_fpr" \
	sh "$rot_block" 2>&1)"
check "while a real override during the same rotation still is one" "OVERRIDE=yes" \
	"$(printf '%s' "$rot_out" | grep '^OVERRIDE=' | head -1)"

# --- the check can see a violation ------------------------------------------
#
# Without this the suite is a comparison that always agrees. A throwaway key in
# a scratch GNUPGHOME stands in for a rotation that someone forgot to mirror
# into the installer, and this file is then run again over that scratch tree.
# Re-running the file itself is the point: a probe that repeated the comparison
# inline would still pass if the extraction above broke, which is the failure
# this file exists to catch. The committed keyring is never touched; the .asc
# is replaced inside a copy of the tree and the copy is removed afterwards.
#
# GLYNDOR_KEYRING_PROBE stops the copy from probing itself, which would not
# terminate.
if [ -z "${GLYNDOR_KEYRING_PROBE:-}" ]; then
	probe="$(mktemp -d)"
	mkdir -p "$probe/keyring" "$probe/scripts" "$probe/tests"
	cp "$INSTALLER" "$probe/scripts/install-template.sh"
	cp "$0" "$probe/tests/$(basename "$0")"

	gpghome="$probe/gnupg"
	mkdir -p "$gpghome"; chmod 700 "$gpghome"
	# A fresh key has a fresh fingerprint, one the installer's default does not
	# contain. That is the violation the check exists to detect.
	GNUPGHOME="$gpghome" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "fixture <f@test.invalid>" default default never \
		>/dev/null 2>&1
	GNUPGHOME="$gpghome" gpg --batch --armor --export "fixture" \
		> "$probe/keyring/glyndor-apt-key.asc"
	GNUPGHOME="$gpghome" gpgconf --kill all >/dev/null 2>&1 || true

	# The planted keyring has to differ from the committed one, or the probe
	# proves nothing about a check that never saw a violation.
	check "the planted keyring is not the committed one" "1" \
		"$(cmp -s "$KEYRING" "$probe/keyring/glyndor-apt-key.asc" && echo 0 || echo 1)"

	probe_rc=0
	probe_out="$(GLYNDOR_KEYRING_PROBE=1 GLYNDOR_KEYRING_ROOT="$probe" \
		bash "$probe/tests/$(basename "$0")" 2>&1)" || probe_rc=$?
	check "and this file refuses a packaged key the installer was not told to expect" \
		"1" "$probe_rc"
	check "and it fails on the acceptance check, not somewhere else" "1" \
		"$(printf '%s' "$probe_out" \
			| grep -qF "FAIL  every primary fingerprint in the packaged keyring is one the installer accepts" \
			&& echo 1 || echo 0)"

	rm -rf "$probe"
fi

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
