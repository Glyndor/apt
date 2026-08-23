#!/bin/sh
# Set up the Glyndor apt repository and install @PRODUCT@.
#
# Usage: ./install.sh
#
# Generated from scripts/install-template.sh in Glyndor/apt. Do not edit the
# published copy - edit the template.
#
# @PRODUCT@ ships as a signed .deb, so apt is the install: it verifies every
# package on every upgrade rather than once, and `apt upgrade` is what keeps the
# machine current. A binary dropped somewhere by hand stays on the version it
# was installed at until somebody remembers it.
#
# Installing through apt also brings podman and podup in on its own - they are
# Recommends of the package, and apt installs those by default.
set -eu

KEYRING_URL="${KEYRING_URL:-https://apt.glyndor.net/glyndor-archive-keyring.deb}"
KEYRING_PATH="/usr/share/keyrings/glyndor.gpg"

# Fingerprint of the archive signing key. Downloading the keyring package is the
# one step that has nothing but the transport behind it; checking what it
# installed against this constant is what closes that window. Override for a
# fork with GLYNDOR_APT_FPR.
GLYNDOR_APT_FPR="${GLYNDOR_APT_FPR:-9ADF04EA8C3139CDB67303CFA6705C2EA153F3D6}"

fail() {
	echo "error: $1" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo sh install.sh)"

command -v apt-get >/dev/null 2>&1 \
	|| fail "no apt-get found. @PRODUCT@ ships as a .deb; on a non-Debian system, build from source (https://github.com/Glyndor/@PRODUCT@)"
command -v dpkg >/dev/null 2>&1 || fail "no dpkg found"

workdir=
installed_gnupg=

# Leaves nothing of its own behind, on every exit path including the failures:
# the downloaded keyring package, and gnupg if this script is what pulled it in.
cleanup() {
	[ -n "$workdir" ] && rm -rf "$workdir"
	if [ -n "$installed_gnupg" ]; then
		echo "Removing the gnupg this script installed ..."
		apt-get purge -y -qq --auto-remove gnupg >/dev/null 2>&1 || true
	fi
	return 0
}
trap cleanup EXIT

# gpg comes from the distribution's own trusted repositories, not ours, so
# installing it here does not widen what has to be trusted. It is needed for one
# fingerprint read and nothing else, so it goes back out again afterwards -
# purged with --auto-remove, and only when it was absent to begin with.
if ! command -v gpg >/dev/null 2>&1; then
	echo "Installing gnupg (needed to check the archive key) ..."
	apt-get update -qq
	apt-get install -y -qq gnupg || fail "could not install gnupg"
	installed_gnupg=yes
fi

workdir=$(mktemp -d)

echo "Downloading the archive keyring ..."
curl -fsSL -o "$workdir/glyndor-archive-keyring.deb" "$KEYRING_URL" \
	|| fail "could not download $KEYRING_URL"

echo "Installing the keyring ..."
dpkg -i "$workdir/glyndor-archive-keyring.deb" >/dev/null \
	|| fail "could not install the keyring package"

echo "Checking the archive key fingerprint ..."
# A rotation ships a keyring carrying both the old and the new key, so the test
# is that the expected fingerprint is present - not that it is the only one.
if ! gpg --show-keys --with-colons "$KEYRING_PATH" 2>/dev/null \
	| awk -F: '/^fpr:/{print $10}' | grep -qx "$GLYNDOR_APT_FPR"; then
	# Leave nothing trusted behind: the key that was just installed is not the
	# one this script expects, and apt would go on using it.
	dpkg --purge glyndor-archive-keyring >/dev/null 2>&1 || true
	fail "the installed archive key does not carry the expected fingerprint ($GLYNDOR_APT_FPR); the keyring package has been removed"
fi

echo "Installing @PRODUCT@ ..."
apt-get update -qq
apt-get install -y @PRODUCT@ || fail "apt could not install @PRODUCT@"

# Automatic upgrades.
#
# The keyring package puts this archive on unattended-upgrades' allowlist, which
# is the part that is ours to decide. Whether the machine runs unattended
# upgrades at all is the operator's, and the two cases are handled differently
# on purpose.
#
# Debian ships neither the package nor the `20auto-upgrades` switch that turns
# it on, so on a fresh Debian the allowlist entry alone does nothing. Ubuntu
# server ships both.
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
	# Already there, so it is configured the way this operator wants it. The
	# keyring's allowlist entry is appended to their list rather than replacing
	# it, so Glyndor packages are already covered by whatever schedule they
	# chose. Nothing here to change, and changing it would be presumptuous.
	echo "unattended-upgrades is already installed; leaving its settings alone."
	if [ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
		echo "  note: it is installed but not switched on. To enable it:"
		echo "        sudo dpkg-reconfigure -plow unattended-upgrades"
	fi
else
	echo "Setting up automatic security upgrades ..."
	if apt-get install -y -qq unattended-upgrades; then
		# Only written because this script is what installed the package, so
		# there is no prior configuration to override.
		if [ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
			cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
		fi
		# Conservative for a server that answers on the public internet. Written
		# in its own file rather than by editing Debian's 50unattended-upgrades,
		# so an operator can drop it with one rm and dpkg never fights over it.
		cat > /etc/apt/apt.conf.d/52glyndor-safety <<'CONF'
// Written by the Glyndor installer, and only because it is what brought
// unattended-upgrades onto this machine. If you already ran unattended
// upgrades, this file was not created and your settings were left untouched.
//
// Never reboot on its own. A service dropping at 06:00 because a kernel landed
// is worse than the delay of a planned reboot, and the operator is the one who
// knows when that window is.
Unattended-Upgrade::Automatic-Reboot "false";

// Upgrade in small steps so an interrupted run leaves a working dpkg state
// rather than a half-configured one.
Unattended-Upgrade::MinimalSteps "true";

// Leave removals to the operator. Automatic dependency and kernel cleanup is
// the part of unattended-upgrades most likely to surprise someone.
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
CONF
		echo "  done: security upgrades apply automatically, without rebooting."
	else
		echo "  warning: could not install unattended-upgrades." >&2
		echo "  @PRODUCT@ will not receive security fixes on its own. Install it later with:" >&2
		echo "        sudo apt install unattended-upgrades" >&2
	fi
fi

echo
echo "Installed: $(@PRODUCT@ --version)"
echo "Upgrades and archive-key renewals both arrive through apt."
