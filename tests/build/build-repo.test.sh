#!/usr/bin/env bash
#
# scripts/build/build-repo.sh decides what gets published and under whose signature,
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

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
# The temporary keyrings the case makes are all under $WORK: every one of them
# is closed on the way out, and none of them is left running. The kill names
# the homedir it belongs to, so the agent of THIS run stops and not the one of
# the machine's own keyring, which the bare form would have killed instead
# while leaving the temporary ones running. The socket dir GnuPG made for each
# homedir is removed as well: GnuPG leaves it behind under
# /run/user/<uid>/gnupg/d.*, and killing the agent does not take it away.
# The verify-* keyrings are named too: they are temporary keyrings of this
# case, and a homedir the loop does not name is a socket dir nobody removes.
cleanup() {
	local dir
	for dir in "$WORK"/gnupg-* "$WORK"/verify-*; do
		[ -d "$dir" ] || continue
		timeout 10 gpgconf --homedir "$dir" --kill all > /dev/null 2>&1 || true
		gpgconf --homedir "$dir" --remove-socketdir > /dev/null 2>&1 || true
	done
	rm -rf "$WORK"
}
trap cleanup EXIT
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
		"$root/scripts/build/build-repo.sh" "$@" >"$WORK/out" 2>&1
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
	mkdir -p "$root/scripts/build" "$root/keyring"
	cp "$HERE/scripts/build/build-repo.sh" "$HERE/scripts/build/build-index-page.sh" "$HERE/scripts/build/add-by-hash.sh" \
		"$root/scripts/build/"
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

# --- Case 5b: the bootstrap package is signed by the key that signs the index --
#
# publish.yml serves the keyring package at the archive root with a detached
# signature the bootstrap installer requires, and build-repo.sh makes it with
# the key it has just imported and checked. reprepro and the landing page are
# stubbed so the case runs where reprepro is not installed; what is under test
# is which key signs and what it signs. The stubs sit on PATH and in the
# throwaway root only for these runs. The reprepro stub exports the smallest
# unsigned distribution (one Packages and the Release that declares it), so the
# real add-by-hash.sh signs it here as it does after a real export.
mkdir -p "$WORK/stubbin"
cat > "$WORK/stubbin/reprepro" <<'STUB'
#!/usr/bin/env bash
# reprepro -b <dir> includedeb ...
d="$2/dists/stable"
mkdir -p "$d/main/binary-amd64"
printf 'Package: testpkg\nVersion: 1.0\n\n' > "$d/main/binary-amd64/Packages"
printf 'Suite: stable\nSHA256:\n %s %s main/binary-amd64/Packages\n' \
	"$(sha256sum < "$d/main/binary-amd64/Packages" | cut -d' ' -f1)" "$(stat -c%s "$d/main/binary-amd64/Packages")" > "$d/Release"
STUB
chmod +x "$WORK/stubbin/reprepro"
stub_root() { # $1=name $2...=uids: mkroot with a landing page that does nothing
	local root
	root="$(mkroot "$@")"
	printf '#!/bin/sh\nexit 0\n' > "$root/scripts/build/build-index-page.sh"
	chmod +x "$root/scripts/build/build-index-page.sh"
	echo "$root"
}
run_stubbed() { PATH="$WORK/stubbin:$PATH" run "$@"; }
verifies_with() { # $1=uid $2=asc $3=data -> 1 when the signature verifies against uid's key
	local home="$WORK/verify-$1"
	rm -rf "$home"; mkdir -p "$home"; chmod 700 "$home"
	pubof "$1" | GNUPGHOME="$home" gpg --batch --quiet --import 2>/dev/null
	GNUPGHOME="$home" gpg --batch --verify "$2" "$3" >/dev/null 2>&1 && echo 1 || echo 0
}
mkpkg() { # $1=Package $2=output path: a minimal real package
	local root="$WORK/pkg-$RANDOM"
	mkdir -p "$root/DEBIAN"
	printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' "$1" > "$root/DEBIAN/control"
	mkdir -p "$(dirname "$2")"
	dpkg-deb --root-owner-group --build "$root" "$2" >/dev/null 2>&1
}
KEYRING_DEB="$WORK/keyring/glyndor-archive-keyring.deb"
mkpkg glyndor-archive-keyring "$KEYRING_DEB"

R_BOOT="$(stub_root r5c alpha)"
rc=0; run_stubbed "$R_BOOT" "$KEY_A" --bootstrap "$KEYRING_DEB" "$WORK/out5c" "$DEB" || rc=$?
check "with --bootstrap the build succeeds" "0" "$rc"
[ "$rc" -eq 0 ] || { echo "        --- build-repo.sh said ---"; sed 's/^/        /' "$WORK/out"; }
check "and the keyring package is served at the root, byte for byte" "1" \
	"$(cmp -s "$KEYRING_DEB" "$WORK/out5c/glyndor-archive-keyring.deb" && echo 1 || echo 0)"
check "and its detached signature verifies against the archive key" "1" \
	"$(verifies_with alpha "$WORK/out5c/glyndor-archive-keyring.deb.asc" "$WORK/out5c/glyndor-archive-keyring.deb")"
check "and not against another key" "0" \
	"$(verifies_with bravo "$WORK/out5c/glyndor-archive-keyring.deb.asc" "$WORK/out5c/glyndor-archive-keyring.deb")"
check "and the signature is a detached one, not the data with it" "1" \
	"$(head -1 "$WORK/out5c/glyndor-archive-keyring.deb.asc" | grep -c -- '-----BEGIN PGP SIGNATURE-----')"
check "and the index is signed with the same key" "1" \
	"$(verifies_with alpha "$WORK/out5c/dists/stable/Release.gpg" "$WORK/out5c/dists/stable/Release")"
check "and offers itself by hash" "1" "$(grep -c '^Acquire-By-Hash: yes$' "$WORK/out5c/dists/stable/Release")"
printf 'tampered\n' >> "$WORK/out5c/glyndor-archive-keyring.deb"
check "and a tampered package no longer verifies against it" "0" \
	"$(verifies_with alpha "$WORK/out5c/glyndor-archive-keyring.deb.asc" "$WORK/out5c/glyndor-archive-keyring.deb")"

# The two-key refusal of case 4 holds for the bootstrap signature too: it is
# the same import, so a secret carrying two keys signs neither the index nor the
# package. Without this, the guard would protect only the index.
R_BOOT2="$(stub_root r5d alpha bravo)"
rc=0; run_stubbed "$R_BOOT2" "$(printf '%s\n%s' "$KEY_A" "$KEY_B")" \
	--bootstrap "$KEYRING_DEB" "$WORK/out5d" "$DEB" || rc=$?
check "with --bootstrap, two secret keys are refused" "1" \
	"$(said 'expected exactly one secret key')"
check "and no bootstrap signature is written" "0" \
	"$([ -e "$WORK/out5d/glyndor-archive-keyring.deb.asc" ] && echo 1 || echo 0)"

rc=0; run_stubbed "$R_BOOT" "$KEY_A" --bootstrap "$WORK/absent-keyring.deb" "$WORK/out5e" "$DEB" || rc=$?
check "a --bootstrap package that does not exist is refused" "1" \
	"$(said 'no such keyring package')"

# Whatever --bootstrap is given is served as the keyring and signed, so it has
# to be the keyring package, by name and by control field. Each refusal is
# paired with the other half right, so it is that half that refuses.
mkpkg glyndor-archive-keyring "$WORK/misnamed/keyring.deb"
rc=0; run_stubbed "$R_BOOT" "$KEY_A" --bootstrap "$WORK/misnamed/keyring.deb" "$WORK/out5f" "$DEB" || rc=$?
check "a --bootstrap file not named glyndor-archive-keyring.deb is refused" "1" \
	"$(said 'takes glyndor-archive-keyring.deb, not keyring.deb')"
mkpkg podup "$WORK/impostor/glyndor-archive-keyring.deb"
rc=0; run_stubbed "$R_BOOT" "$KEY_A" --bootstrap "$WORK/impostor/glyndor-archive-keyring.deb" "$WORK/out5g" "$DEB" || rc=$?
check "a package under the keyring's name that is another package is refused" "1" \
	"$(said 'is not the glyndor-archive-keyring package')"
check "and nothing is served for it" "0" "$([ -e "$WORK/out5g/glyndor-archive-keyring.deb.asc" ] && echo 1 || echo 0)"

# --- Case 5e: no process started after the import can read the private key ---
#
# `unset GLYNDOR_APT_GPG_PRIVATE_KEY` is not a refusal, so no case above notices
# it going: reprepro is third-party code installed in the job that holds the
# key, and with the line gone it runs with the key in its environment while
# every output stays the same. Each program build-repo.sh starts here is a
# probe that records whether the variable is in its environment: reprepro
# (which dumps all of it), the landing page script, gpg and gpgconf, and the
# add-by-hash.sh that signs. The import is the one call that must see it, which
# is what shows the probes can see the variable at all.
PROBEBIN="$WORK/probebin"; LEAKS="$WORK/leaks"
mkdir -p "$PROBEBIN"
REAL_GPG="$(command -v gpg)"; REAL_GPGCONF="$(command -v gpgconf)"
export LEAKS REAL_GPG REAL_GPGCONF
cat > "$PROBEBIN/reprepro" <<'PROBE'
#!/usr/bin/env bash
env > "$LEAKS.reprepro-env"
if grep -q '^GLYNDOR_APT_GPG_PRIVATE_KEY=' "$LEAKS.reprepro-env"; then echo "reprepro" >> "$LEAKS"; fi
exec "$STUBBIN_REPREPRO" "$@"
PROBE
for tool in gpg gpgconf; do
	cat > "$PROBEBIN/$tool" <<PROBE
#!/usr/bin/env bash
if env | grep -q '^GLYNDOR_APT_GPG_PRIVATE_KEY='; then echo "$tool \$*" >> "\$LEAKS"; fi
exec "\$REAL_${tool^^}" "\$@"
PROBE
done
chmod +x "$PROBEBIN/reprepro" "$PROBEBIN/gpg" "$PROBEBIN/gpgconf"
export STUBBIN_REPREPRO="$WORK/stubbin/reprepro"
# The probe scripts are written with single quotes on purpose: what they expand
# is theirs to expand, when they run.
# shellcheck disable=SC2016
probe_root() { # $1=name: stub_root whose landing page and signer record their environment
	local root
	root="$(stub_root "$1" alpha)"
	printf '#!/usr/bin/env bash\nenv | grep -q "^GLYNDOR_APT_GPG_PRIVATE_KEY=" && echo build-index-page >> "$LEAKS"\nexit 0\n' \
		> "$root/scripts/build/build-index-page.sh"
	mv "$root/scripts/build/add-by-hash.sh" "$root/scripts/build/add-by-hash-real.sh"
	printf '#!/usr/bin/env bash\nenv | grep -q "^GLYNDOR_APT_GPG_PRIVATE_KEY=" && echo add-by-hash >> "$LEAKS"\nexec "$(dirname "$0")/add-by-hash-real.sh" "$@"\n' \
		> "$root/scripts/build/add-by-hash.sh"
	chmod +x "$root/scripts/build/build-index-page.sh" "$root/scripts/build/add-by-hash.sh"
	echo "$root"
}
R_LEAK="$(probe_root r5e)"
: > "$LEAKS"
rc=0; PATH="$PROBEBIN:$PATH" run "$R_LEAK" "$KEY_A" --bootstrap "$KEYRING_DEB" "$WORK/out5e2" "$DEB" || rc=$?
check "with every program probed, the build still succeeds" "0" "$rc"
[ "$rc" -eq 0 ] || { echo "        --- build-repo.sh said ---"; sed 's/^/        /' "$WORK/out"; }
check "the import is a probed call that sees the key, so the probes can see the variable" "1" \
	"$(grep -c '^gpg --batch --quiet --import$' "$LEAKS")"
check "and it is the only call that sees it" "1" "$(grep -c . "$LEAKS")"
check "reprepro does not have the key in its environment" "0" "$(grep -c '^reprepro$' "$LEAKS")"
check "the environment reprepro dumped is a real one, not an empty file" "1" \
	"$(grep -c '^GNUPGHOME=' "$LEAKS.reprepro-env")"
check "add-by-hash.sh does not have it" "0" "$(grep -c '^add-by-hash$' "$LEAKS")"
check "the landing page script does not have it" "0" "$(grep -c '^build-index-page$' "$LEAKS")"
check "no gpg call after the import has it" "0" "$(grep '^gpg ' "$LEAKS" | grep -vc -- '--import$')"
check "gpgconf does not have it at cleanup" "0" "$(grep -c '^gpgconf' "$LEAKS")"

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
	rc=0; run "$R" "$KEY_A" --bootstrap "$KEYRING_DEB" "$WORK/out6" "$REAL" || rc=$?
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
	check "and the bootstrap package is signed by the key that signed the index" "1" \
		"$(verifies_with alpha "$WORK/out6/glyndor-archive-keyring.deb.asc" "$WORK/out6/glyndor-archive-keyring.deb")"
else
	echo "NOTE  reprepro is not installed here, so the end-to-end case did not"
	echo "      run. The guard cases above ran; nothing was counted for this one."
fi

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
