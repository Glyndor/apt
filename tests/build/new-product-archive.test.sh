#!/usr/bin/env bash
#
# What the archive does with helmly and epistle-panel once their packages are
# admitted, run from a release that does not exist yet: the bootstrap installer
# each product gets, and the build of the archive from a minimal package of
# helmly (amd64 and arm64) and one of epistle-panel (`all`). The packages are
# built here and are not signed: admission is tests/verify/new-product-end-to-end.test.sh.
# Nothing here reads the real roster.
#
# reprepro is replaced by a stub that records what it was asked to include, so
# the case runs where reprepro is not installed: what is under test is that the
# build hands the archive exactly the packages it was given, an `all` package
# among them, and signs the index with the archive key.
#
# Requires: bash, dpkg-deb, gpg.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
# The archive keyring the case makes is a temporary one: its agent is closed
# before the folder goes, and the kill names the homedir it belongs to, so the
# agent of THIS run stops and not the one of the machine's own keyring. The
# socket dir GnuPG made for that homedir is removed as well: GnuPG leaves it
# behind under /run/user/<uid>/gnupg/d.*, and killing the agent does not take
# it away.
GH_HOME=""
cleanup() {
	if [ -n "$GH_HOME" ]; then
		timeout 10 gpgconf --homedir "$GH_HOME" --kill all > /dev/null 2>&1 || true
		gpgconf --homedir "$GH_HOME" --remove-socketdir > /dev/null 2>&1 || true
	fi
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
build_deb() { # <dir> <file name> <Package> <Version> <Architecture>
	local root="$WORK/root-$RANDOM"
	mkdir -p "$root/DEBIAN" "$1"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture of %s\n' \
		"$3" "$4" "$5" "$3" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$1/$2" > /dev/null 2>&1
}
build_deb "$WORK/helmly" helmly_1.2.3_amd64.deb helmly 1.2.3 amd64
build_deb "$WORK/helmly" helmly_1.2.3_arm64.deb helmly 1.2.3 arm64
build_deb "$WORK/panel" epistle-panel_1.2.3_all.deb epistle-panel 1.2.3 all

# --- the names the installer and the archive derive from the roster -------------
"$HERE/scripts/build/build-installers.sh" "$WORK/installers" helmly epistle-panel > "$WORK/out" 2>&1
installers=""
for p in helmly epistle-panel; do [ -x "$WORK/installers/$p" ] && installers="${installers}1" || installers="${installers}0"; done
check "an installer is built for each product" "11" "$installers"
check "and each one carries the package of its own name and nothing left to fill in" "1 1 0" \
	"$(grep -qF helmly "$WORK/installers/helmly" && echo 1) $(grep -qF epistle-panel "$WORK/installers/epistle-panel" && echo 1) $(grep -c '@PRODUCT@' "$WORK/installers/helmly" "$WORK/installers/epistle-panel" | awk -F: '{n+=$2} END{print n}')"

# --- the archive takes the verified packages ------------------------------------
# reprepro is replaced by a stub that records what it was asked to include, so the
# case runs where reprepro is not installed: what is under test is that the
# build hands the archive exactly the verified packages, and under the archive key.
mkdir -p "$WORK/stubbin" "$WORK/build/scripts/build" "$WORK/build/keyring"
cat > "$WORK/stubbin/reprepro" <<'STUB'
#!/usr/bin/env bash
# reprepro -b <dir> includedeb <distribution> <deb>
printf '%s\n' "$@" >> "$STUB_LOG"
d="$2/dists/stable"; mkdir -p "$d/main/binary-amd64"
printf 'Package: x\nVersion: 1\n\n' > "$d/main/binary-amd64/Packages"
printf 'Suite: stable\nSHA256:\n %s %s main/binary-amd64/Packages\n' \
	"$(sha256sum < "$d/main/binary-amd64/Packages" | cut -d' ' -f1)" "$(stat -c%s "$d/main/binary-amd64/Packages")" > "$d/Release"
STUB
chmod +x "$WORK/stubbin/reprepro"
cp "$HERE/scripts/build/build-repo.sh" "$HERE/scripts/build/add-by-hash.sh" "$WORK/build/scripts/build/"
printf '#!/bin/sh\nexit 0\n' > "$WORK/build/scripts/build/build-index-page.sh"; chmod +x "$WORK/build/scripts/build/build-index-page.sh"
GH_HOME="$WORK/gnupg-archive"; mkdir -p "$GH_HOME"; chmod 700 "$GH_HOME"
GNUPGHOME="$GH_HOME" gpg --batch --quiet --passphrase '' --quick-generate-key "archive <archive@test.invalid>" default default never > /dev/null 2>&1
GNUPGHOME="$GH_HOME" gpg --batch --armor --export archive > "$WORK/build/keyring/glyndor-apt-key.asc"
ARCHIVE_KEY="$(GNUPGHOME="$GH_HOME" gpg --batch --armor --export-secret-keys archive)"
: > "$WORK/stub.log"
rc=0
PATH="$WORK/stubbin:$PATH" STUB_LOG="$WORK/stub.log" GLYNDOR_APT_GPG_PRIVATE_KEY="$ARCHIVE_KEY" \
	"$WORK/build/scripts/build/build-repo.sh" "$WORK/archive" "$WORK/helmly/helmly_1.2.3_amd64.deb" "$WORK/helmly/helmly_1.2.3_arm64.deb" \
	"$WORK/panel/epistle-panel_1.2.3_all.deb" > "$WORK/out" 2>&1 || rc=$?
check "the archive is built from the three verified packages" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$WORK/out"
check "and each of them was handed to the archive" "3" "$(grep -c '_1.2.3_.*\.deb$' "$WORK/stub.log")"
check "and the architecture all package among them" "1" "$(grep -c 'epistle-panel_1.2.3_all.deb$' "$WORK/stub.log")"
check "and the index is signed" "1" "$([ -s "$WORK/archive/dists/stable/Release.gpg" ] && echo 1 || echo 0)"


echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
