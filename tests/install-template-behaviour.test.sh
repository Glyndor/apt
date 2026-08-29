#!/usr/bin/env bash
#
# tests/install-template.test.sh asserts the ORDER of the installer's steps:
# extract, then check the fingerprint, then install. That is a structural
# property, and it is not enough.
#
# Replacing `grep -qx "$GLYNDOR_APT_FPR"` with `grep -q ""` leaves the order
# untouched and makes the installer accept any key at all. The ordering suite
# stays green through that mutation. It was green through it when I tried.
#
# So this file runs the installer. It serves a keyring package over file://
# (KEYRING_URL is overridable) and asserts what the installer DOES with keys
# that are right, wrong, and hostile.
#
# `dpkg` is stubbed to record that it was called rather than to install
# anything, which is what lets "nothing was installed" be asserted rather than
# assumed: the marker file is absent exactly when the installer refused before
# reaching `dpkg -i`. `id` is stubbed to report uid 0, since the installer
# checks for root before anything else and this test is not root -- the fixture
# has to be valid in every respect except the one under test.
#
# Requires: gpg, dpkg-deb, curl with the file:// protocol.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$HERE/scripts/install-template.sh"
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

for tool in gpg dpkg-deb curl; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "NOTE  $tool is not installed here, so nothing below could run."
		echo "      This is not a pass. Install $tool and run again."
		exit 1
	}
done
curl --version | grep -q '\bfile\b' || {
	echo "NOTE  this curl has no file:// protocol, so the fixtures cannot be served."
	echo "      This is not a pass."
	exit 1
}

# --- key material -----------------------------------------------------------

mkkey() { # $1=uid -> prints the 40-char fingerprint
	local home="$WORK/gnupg-$1"
	mkdir -p "$home"; chmod 700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "$1 <$1@test.invalid>" default default never \
		>/dev/null 2>&1
	GNUPGHOME="$home" gpg --batch --with-colons --list-keys "$1" \
		| awk -F: '/^fpr:/{print $10; exit}'
}
export_ring() { # $1=uid $2=output file  (binary keyring, as the package ships)
	GNUPGHOME="$WORK/gnupg-$1" gpg --batch --export "$1" > "$2"
}

FPR_GOOD="$(mkkey good)"
# The incoming key of a rotation: legitimate, and published alongside the old
# one during the overlap.
FPR_NEW="$(mkkey new)"
# Needed for the keyring it creates, not for the value.
mkkey evil >/dev/null

# --- fixture packages -------------------------------------------------------

# $1=name  $2=uids whose keys go into the shipped keyring  $3=postinst? (yes|no)
mkdeb() {
	local name="$1" uids="$2" postinst="$3"
	local root="$WORK/pkg-$name"
	rm -rf "$root"
	mkdir -p "$root/DEBIAN" "$root/usr/share/keyrings"
	printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
		> "$root/DEBIAN/control"
	: > "$root/usr/share/keyrings/glyndor.gpg"
	local u
	for u in $uids; do
		export_ring "$u" "$WORK/ring-$u.gpg"
		cat "$WORK/ring-$u.gpg" >> "$root/usr/share/keyrings/glyndor.gpg"
	done
	if [ "$postinst" = yes ]; then
		# What a hostile keyring package would do: rewrite the installed keyring
		# from its maintainer script, so that a check reading the INSTALLED file
		# would find the expected fingerprint. `dpkg-deb -x` never runs this.
		cat > "$root/DEBIAN/postinst" <<POST
#!/bin/sh
cat "$WORK/ring-good.gpg" "$WORK/ring-evil.gpg" > /usr/share/keyrings/glyndor.gpg
POST
		chmod 755 "$root/DEBIAN/postinst"
	fi
	dpkg-deb --root-owner-group --build "$root" "$WORK/$name.deb" >/dev/null 2>&1
	echo "$WORK/$name.deb"
}

# --- the sandbox the installer runs in --------------------------------------

# The stub directory goes FIRST on PATH and shadows the three commands that
# must not do their real work. Whitelisting the rest instead of shadowing was
# the first attempt and it was wrong: `dpkg-deb -x` shells out to `tar`, which
# was not on the list, so every case failed extraction -- including the one that
# should have been accepted, and the hostile one, which then "passed" for the
# wrong reason. The assertion that names WHICH refusal fired is what caught it.
BIN="$WORK/bin"
mkdir -p "$BIN"
# uid 0 without being root: the root check runs first and is not what is tested.
printf '#!/bin/sh\necho 0\n' > "$BIN/id"; chmod +x "$BIN/id"
# apt-get must exist and succeed; nothing here installs a package.
printf '#!/bin/sh\nexit 0\n' > "$BIN/apt-get"; chmod +x "$BIN/apt-get"
# dpkg records that it was reached instead of installing. Its absence is the
# assertion that the installer refused before `dpkg -i`.
cat > "$BIN/dpkg" <<'STUB'
#!/bin/sh
case "$1" in
	-i) echo "$*" >> "$DPKG_MARKER" ;;
esac
exit 0
STUB
chmod +x "$BIN/dpkg"

# $1=deb path  $2=expected fingerprint  -> exit code, output in $WORK/out,
# marker in $WORK/marker
run_installer() {
	rm -f "$WORK/marker"
	sed 's/@PRODUCT@/testpkg/g' "$TEMPLATE" > "$WORK/install.sh"
	# APT_CONF_D points into the sandbox so the installer's last block writes
	# there instead of into /etc. Without it this suite reads the machine it
	# runs on: a host that already has 20auto-upgrades takes the do-nothing
	# branch and every case passes, while one without it tries to write to /etc
	# as a non-root user and every acceptance case fails. That is exactly what
	# happened -- green here, seven failures on the runner -- and the difference
	# was the host, not the installer.
	mkdir -p "$WORK/apt.conf.d"
	env -i PATH="$BIN:$PATH" HOME="$WORK" \
		DPKG_MARKER="$WORK/marker" \
		KEYRING_URL="file://$1" \
		GLYNDOR_APT_FPR="$2" \
		APT_CONF_D="$WORK/apt.conf.d" \
		/bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }
installed() { [ -f "$WORK/marker" ] && echo 1 || echo 0; }

# --- the expected key is accepted -------------------------------------------
#
# Without this, every refusal below is satisfied by an installer that refuses
# everything.
DEB="$(mkdeb good good no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check "a keyring carrying the expected key is accepted" "0" "$rc"
check "and dpkg -i was reached" "1" "$(installed)"

# --- a different key is refused ---------------------------------------------
DEB="$(mkdeb evil evil no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check "a keyring carrying a different key is refused" "1" "$rc"
check "and the message names the expected fingerprint" "1" "$(said "$FPR_GOOD")"
check "and says nothing was installed" "1" "$(said 'nothing was installed')"
check "and dpkg -i was never reached" "0" "$(installed)"

# --- a rotation keyring is accepted, an enriched one is not -----------------
#
# standards/releases mandates a two-phase rotation that ships the old and the
# new key together, so a keyring carrying two keys must still install. What it
# must NOT do is install a keyring carrying a key nobody published.
#
# The installer used to test for presence: the published fingerprint had to be
# in there, and anything alongside it came too. That admitted a keyring holding
# the real key AND an attacker's, which apt then trusted equally -- and the
# sources.list the same package installs decides where apt fetches from. The
# published fingerprint could not catch it, because the published fingerprint
# was present. Measured before the change: such a package reached `dpkg -i`.
#
# So both fingerprints go in during an overlap, and every key in the keyring
# must be one of them.
DEB="$(mkdeb rotation "good new" no)"
rc=0; run_installer "$DEB" "$FPR_GOOD,$FPR_NEW" || rc=$?
check "a rotation keyring carrying both published keys is accepted" "0" "$rc"
check "and dpkg -i was reached" "1" "$(installed)"

# Phase two: the old key is dropped and only the new one ships. Still accepted,
# because it is still a published fingerprint.
DEB="$(mkdeb rotated "new" no)"
rc=0; run_installer "$DEB" "$FPR_GOOD,$FPR_NEW" || rc=$?
check "and so is one carrying only the incoming key" "0" "$rc"

# The attack the presence test admitted. One published fingerprint, a keyring
# carrying it plus a key that was never published.
DEB="$(mkdeb enriched "good evil" no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check "a keyring carrying an unpublished key alongside is refused" "1" "$rc"
check "and the message names the key that was not expected" "1" "$(said 'was not told to expect')"
check "and dpkg -i was never reached" "0" "$(installed)"

# --- the exploit ------------------------------------------------------------
#
# This package ships only the attacker's key, and carries a postinst that would
# rewrite the installed keyring to contain the expected fingerprint. Under the
# old order -- `dpkg -i` first, then read /usr/share/keyrings/glyndor.gpg -- the
# check would find what it was looking for and pass.
#
# `dpkg-deb -x` unpacks the data archive and runs no maintainer script, so the
# fingerprint is read from what the package SHIPS rather than from what it was
# allowed to write.
DEB="$(mkdeb hostile evil yes)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check "a package whose postinst would forge the keyring is refused" "1" "$rc"
check "and it is refused for the key, not something else" "1" \
	"$(said 'was not told to expect')"
check "and its maintainer script was never given the chance to run" "0" \
	"$(installed)"

# --- the published fingerprint can be pasted in the form it is published -----
#
# gpg prints a fingerprint in groups, and the README publishes it that way. The
# override documented in the script says nothing about format, so a fork
# operator copies what is on the page. Before it was normalised, that produced
# "does not carry the expected fingerprint" -- an error pointing at the key when
# the fault was the spaces.
DEB="$(mkdeb spaced good no)"
SPACED="$(printf '%s' "$FPR_GOOD" | sed 's/\(....\)/\1 /g; s/ $//')"
rc=0; run_installer "$DEB" "$SPACED" || rc=$?
check "a fingerprint pasted with gpg's spacing is accepted" "0" "$rc"
check "and dpkg -i was reached" "1" "$(installed)"

# Lower case too: some tools print fingerprints that way.
rc=0; run_installer "$DEB" "$(printf '%s' "$FPR_GOOD" | tr 'A-F' 'a-f')" || rc=$?
check "a lower-case fingerprint is accepted" "0" "$rc"

# Normalising must not make the check lax. A wrong key spelled with spaces is
# still a wrong key.
DEB="$(mkdeb spaced-evil evil no)"
rc=0; run_installer "$DEB" "$SPACED" || rc=$?
check "and a spaced fingerprint still refuses the wrong key" "1" "$rc"
check "and nothing was installed" "0" "$(installed)"

# --- a replaced default announces itself ------------------------------------
#
# Both overrides exist for forks and both used to be silent. The case that
# matters is a copied command line where the visible URL is the real one and the
# substitution sits in the environment, past where a reader looks.
#
# Nothing here blocks the override -- that would break the fork it was written
# for. The assertion is that the screen says what is in use.
DEB="$(mkdeb spaced2 good no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check "the stock install still succeeds" "0" "$rc"

# There is no un-overridden case to assert here, and pretending otherwise would
# be a test that cannot pass. This harness serves its fixture over file:// and
# signs it with a generated key, so KEYRING_URL and GLYNDOR_APT_FPR are BOTH
# always replaced. The quiet path -- neither overridden -- exists only against
# the real archive with the real key, which this suite does not reach.
check "a replaced keyring source is announced" "1" \
	"$(said 'keyring source:')"

# Both replaced is the combination where nothing traces back to Glyndor's
# published key, and it gets its own sentence.
DEB="$(mkdeb spaced3 evil no)"
FPR_EVIL_REAL="$(GNUPGHOME="$WORK/gnupg-evil" gpg --batch --with-colons --list-keys evil \
	| awk -F: '/^fpr:/{print $10; exit}')"
rc=0; run_installer "$DEB" "$FPR_EVIL_REAL" || rc=$?
check "a keyring and a fingerprint that both differ still installs" "0" "$rc"
check "and the run says nothing traces back to Glyndor's key" "1" \
	"$(said 'nothing here is checked against Glyndor')"

# --- a download that does not arrive ----------------------------------------
rc=0; run_installer "$WORK/absent.deb" "$FPR_GOOD" || rc=$?
check "a keyring that cannot be downloaded is refused" "1" "$rc"
check "and says so" "1" "$(said 'could not download')"
check "and nothing was installed" "0" "$(installed)"

# --- something that is not a .deb -------------------------------------------
printf 'this is not a debian package' > "$WORK/junk.deb"
rc=0; run_installer "$WORK/junk.deb" "$FPR_GOOD" || rc=$?
check "a download that is not a .deb is refused" "1" "$rc"
check "and says extraction failed" "1" "$(said 'could not extract')"
check "and nothing was installed" "0" "$(installed)"

# --- an oversized download is refused ---------------------------------------
#
# The keyring is about 2 KB and stays kilobytes carrying both keys through a
# rotation. A server answering that request with an endless body used to be
# bounded by the disk alone, and this runs as root: /tmp filling up takes the
# machine with it, before any fingerprint is compared. curl's --max-filesize
# refuses it mid-transfer.
#
# A VALID .deb, oversized. A blob of zeroes would be refused by `dpkg-deb -x`
# whether or not the cap exists, so the test would pass with the cap removed --
# measured, it did. The fixture has to be invalid in the one respect under test
# and correct in every other, or it proves nothing.
#
# Incompressible padding, so the built package really exceeds the 8 MB cap
# rather than compressing back under it.
big="$WORK/pkg-big"
rm -rf "$big"; mkdir -p "$big/DEBIAN" "$big/usr/share/keyrings" "$big/usr/share/doc"
printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
	> "$big/DEBIAN/control"
export_ring good "$big/usr/share/keyrings/glyndor.gpg"
head -c $((9 * 1024 * 1024)) /dev/urandom > "$big/usr/share/doc/padding"
dpkg-deb -Znone --root-owner-group --build "$big" "$WORK/huge.deb" >/dev/null 2>&1

rc=0; run_installer "$WORK/huge.deb" "$FPR_GOOD" || rc=$?
check "a download larger than the cap is refused" "1" "$rc"
check "and it is refused at the download, not later" "1" "$(said 'could not download')"
check "and nothing was installed" "0" "$(installed)"

# --- a .deb carrying no keyring at all --------------------------------------
#
# `gpg --show-keys` on a missing file yields nothing, and an empty fingerprint
# list must not satisfy the comparison.
root="$WORK/pkg-empty"; mkdir -p "$root/DEBIAN"
printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
	> "$root/DEBIAN/control"
dpkg-deb --root-owner-group --build "$root" "$WORK/empty.deb" >/dev/null 2>&1
rc=0; run_installer "$WORK/empty.deb" "$FPR_GOOD" || rc=$?
check "a package shipping no keyring is refused" "1" "$rc"
check "and nothing was installed" "0" "$(installed)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
