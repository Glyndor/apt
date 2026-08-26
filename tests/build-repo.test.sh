#!/usr/bin/env bash
#
# scripts/build-repo.sh decides what gets published and under whose signature,
# and had no test. Every case here asserts WHICH refusal fired, never that some
# refusal did: `set -euo pipefail` means almost any mistake exits non-zero, so a
# bare "it failed" assertion is satisfied by the failure you did not mean.
#
# Each rejection is paired with an acceptance of the same shape just inside the
# limit. Without that, a fixture rejected for an unrelated reason satisfies the
# rejection and proves nothing.
#
# The script derives its repository root from BASH_SOURCE, so the fixtures build
# a throwaway root holding scripts/ and keyring/ and run the copy inside it.
# That is what makes it possible to test the signing guard with a key that is
# not the real archive key.
#
# Requires: gpg. reprepro is needed only by the full-run case, which says so
# when it is absent rather than counting a pass for something it did not run.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Run build-repo.sh inside a throwaway root and report the exit code plus a
# distinctive fragment of what it said, so a case can name its own refusal.
run() { # $1=root $2=private-key-armor $3...=args
	local root="$1" key="$2"; shift 2
	GLYNDOR_APT_GPG_PRIVATE_KEY="$key" \
		"$root/scripts/build-repo.sh" "$@" >"$WORK/out" 2>&1
}

said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

# --- key material -----------------------------------------------------------
#
# Ephemeral keys, generated once and reused across cases. Generating them per
# case would triple the runtime for no extra coverage.

mkkey() { # $1=uid -> prints the armored secret key
	local home="$WORK/gnupg-$1"
	mkdir -p "$home"; chmod 700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "$1 <$1@test.invalid>" default default never \
		>/dev/null 2>&1
	GNUPGHOME="$home" gpg --batch --armor --export-secret-keys "$1"
}
pubof() { # $1=uid -> prints the armored public key
	GNUPGHOME="$WORK/gnupg-$1" gpg --batch --armor --export "$1"
}

KEY_A="$(mkkey alpha)"
KEY_B="$(mkkey bravo)"

# A root with scripts/ and a keyring/ holding whichever public keys are named.
mkroot() { # $1=name $2...=uids whose public keys go in the keyring
	local root="$WORK/$1"; shift
	mkdir -p "$root/scripts" "$root/keyring"
	cp "$HERE/scripts/build-repo.sh" "$HERE/scripts/build-index-page.sh" \
		"$root/scripts/"
	: > "$root/keyring/glyndor-apt-key.asc"
	local u
	for u in "$@"; do pubof "$u" >> "$root/keyring/glyndor-apt-key.asc"; done
	echo "$root"
}

# A .deb only has to exist for the argument checks; the guards under test run
# long before reprepro reads it.
DEB="$WORK/fixture.deb"; : > "$DEB"

# --- Case 1: no .deb arguments ----------------------------------------------
R="$(mkroot r1 alpha)"
run "$R" "$KEY_A" "$WORK/out1"
check "no .deb argument is refused" "1" "$(said 'no .deb files given')"

# Acceptance of the same shape: one argument more, and it gets past this guard.
run "$R" "$KEY_A" "$WORK/out1" "$DEB"
check "and one .deb argument gets past that guard" "0" "$(said 'no .deb files given')"

# --- Case 2: a .deb path that does not exist --------------------------------
run "$R" "$KEY_A" "$WORK/out2" "$WORK/absent.deb"
check "a missing .deb is refused" "1" "$(said 'no such .deb')"
check "and the message names the path" "1" "$(said 'absent.deb')"

run "$R" "$KEY_A" "$WORK/out2" "$DEB"
check "and an existing .deb gets past that guard" "0" "$(said 'no such .deb')"

# --- Case 3: the committed public keyring is missing ------------------------
R_NOKEY="$(mkroot r3)"
rm -f "$R_NOKEY/keyring/glyndor-apt-key.asc"
run "$R_NOKEY" "$KEY_A" "$WORK/out3" "$DEB"
check "a missing public keyring is refused" "1" "$(said 'missing public key')"

# --- Case 4: the secret carries more than one key ---------------------------
#
# This is the guard that stops a rotation paste ("old + new") from silently
# signing with whichever key imported first.
R2="$(mkroot r4 alpha bravo)"
# The two blocks must be separated by a newline. `$(...)` strips the trailing
# one, so plain concatenation runs "-----END..." into "-----BEGIN..." and gpg
# imports only the first key -- a fixture that is invalid in exactly the respect
# it claims to test, and it passed the guard for that reason on the first run.
run "$R2" "$(printf '%s\n%s' "$KEY_A" "$KEY_B")" "$WORK/out4" "$DEB"
check "two secret keys are refused" "1" \
	"$(said 'expected exactly one secret key')"
check "and the error reports how many it found" "1" "$(said 'found 2')"

# Acceptance just inside the limit: exactly one key, same keyring.
run "$R2" "$KEY_A" "$WORK/out4b" "$DEB"
check "and exactly one secret key gets past that guard" "0" \
	"$(said 'expected exactly one secret key')"

# --- Case 5: the signing key is not in the committed keyring ----------------
#
# The keyring holds bravo; the secret is alpha. This is the control that stops
# the archive being signed by a key clients were never told to trust.
R_B="$(mkroot r5 bravo)"
run "$R_B" "$KEY_A" "$WORK/out5" "$DEB"
check "a signing key absent from the keyring is refused" "1" \
	"$(said 'is not present in')"

# Acceptance: a keyring carrying BOTH keys must admit alpha. A rotation ships
# the old and the new key together, so this guard has to match against every
# key in the .asc -- narrowing it to the first would break every rotation.
R_AB="$(mkroot r5b bravo alpha)"
run "$R_AB" "$KEY_A" "$WORK/out5b" "$DEB"
check "and a keyring carrying it among others admits it" "0" \
	"$(said 'is not present in')"

# --- Case 6: the whole path, when the machine can run it --------------------
#
# Everything above stops before reprepro. This case is the only one that proves
# the guards admit a real build rather than merely failing later.
if command -v reprepro >/dev/null 2>&1; then
	REAL="$WORK/fixture-real.deb"
	pkg="$WORK/pkgroot"
	mkdir -p "$pkg/DEBIAN"
	# Section and Priority are not optional here. reprepro refuses a package
	# without a section ("No section given for 'testpkg', skipping.") and the
	# build fails -- a fixture missing them does not resemble what
	# dpkg-buildpackage produces for a real Glyndor package, so it would be
	# testing a shape this script never receives.
	printf 'Package: testpkg\nVersion: 1.0\nArchitecture: amd64\nSection: utils\nPriority: optional\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
		> "$pkg/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$pkg" "$REAL" >/dev/null 2>&1
	rc=0; run "$R" "$KEY_A" "$WORK/out6" "$REAL" || rc=$?
	check "a valid build succeeds end to end" "0" "$rc"
	# This is the only case that runs the real tool chain, so when it fails the
	# reason has to reach whoever reads the log. Without this the failure is a
	# bare exit code and the next step is a round trip through CI.
	[ "$rc" -eq 0 ] || { echo "        --- build-repo.sh said ---"; sed 's/^/        /' "$WORK/out"; }
	check "and the signed Release exists" "1" \
		"$([ -f "$WORK/out6/dists/stable/Release.gpg" ] || \
		  [ -f "$WORK/out6/dists/stable/InRelease" ] && echo 1 || echo 0)"
	check "and reprepro bookkeeping is not left to be served" "0" \
		"$(find "$WORK/out6" -maxdepth 1 \( -name conf -o -name db \) | wc -l)"
else
	echo "NOTE  reprepro is not installed here, so the end-to-end case did not"
	echo "      run. The guard cases above ran; nothing was counted for this one."
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
