#!/usr/bin/env bash
#
# The installer decides whether unattended-upgrades runs on its own by asking
# `apt-config dump`, not by asking whether the file by that name exists. The
# file-existence shortcut this replaces reported a 20auto-upgrades with
# APT::Periodic::Unattended-Upgrade "0" as "already on" to the operator who
# wrote it and went on to overwrite the value to "1" without asking. The new
# function reads the value and returns on, off, or unknown; the installer
# prints one of three messages and writes nothing in the off or unknown cases.
#
# Four observations the screen must show correctly:
#
#   1. APT::Periodic::Unattended-Upgrade "0" -> "switched off, left alone"
#   2. APT::Periodic::Unattended-Upgrade "1" -> "already on, left alone"
#                                             (when the archive is allowed)
#   3. no APT::Periodic keys at all        -> "could not determine"
#   4. a file present with non-config text -> "could not determine"
#                                             (the file's contents are not
#                                              apt configuration, so apt reads
#                                              it as no APT::Periodic keys)
#
# Tests 5+ are the archive-side ones (#194): what the operator is told when
# the switch is on. The fixtures that used a placeholder file as evidence of
# "the operator had this set" pinned the file-existence shortcut; they now
# use a file with the real APT::Periodic values, which is what a real machine
# with the keyring installed looks like.
#
# This runs the real block out of the shipped script rather than a copy,
# with `/etc/apt/apt.conf.d` redirected into a temporary tree, `apt-config`
# stubbed, so what is asserted is what the installer does rather than what
# it looks like.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/install-template.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Cut the block out of the shipped script by its own markers, so this cannot
# drift from what ships. A copy pasted in here would keep passing after the
# original changed, which is the failure this whole file exists to catch.
extract_block() {
	awk '/^# --- automatic upgrades ---/,/^# --- end automatic upgrades ---/' "$SCRIPT"
}

# The block calls step() and doing(), which the installer defines near the top.
# Running the block without them does not error out loudly -- `sh` reports
# "not found" and carries on -- so the block would write the right files while
# saying nothing, and the assertions about what it says would fail with no clue
# why. Extract the definitions and prepend them.
extract_output_layer() {
	awk '/^# --- output ---/,/^# --- end output ---/' "$SCRIPT"
}

output_layer="$(extract_output_layer)"
# Emptiness only catches a missing OPENING marker. Drop the closing one and awk
# runs to end of file: the extract is not empty, it is the rest of the script,
# and the upgrades block would then be defined twice and run twice. So check
# what the extract contains at both ends -- it has to define the functions the
# block calls, and it has to have stopped before the block itself.
#
# 20auto-upgrades is the keyword used by the surrounding block; appearing in
# the output layer means the extract ran past the closing marker and picked
# up a snippet of the block.
case "$output_layer" in
	*"step()"*) : ;;
	*)
		echo "FAIL  the output layer in $SCRIPT does not define step()" >&2
		echo "      its opening marker moved; the block would run without it" >&2
		exit 1
		;;
esac
case "$output_layer" in
	*'20auto-upgrades'*)
		echo "FAIL  the output layer extract ran past its closing marker" >&2
		echo "      it swallowed the upgrades block, which would then run twice" >&2
		exit 1
		;;
esac

block="$(extract_block)"
if [ -z "$block" ]; then
	echo "FAIL  could not find the automatic-upgrades block in $SCRIPT" >&2
	echo "      its opening marker changed; this test is now measuring nothing" >&2
	exit 1
fi
# Emptiness only catches a missing OPENING marker; drop the closing one and awk
# runs to end of file, so the extract is not empty, it is the rest of the
# script. Same failure the output layer's guard was widened for.
#
# The sentinel is the function DEFINITION, not its name: the block calls
# archive_upgrade_state, so matching the bare name fired on a correct extract.
case "$block" in
	*'archive_upgrade_state() {'*)
		echo "FAIL  the automatic-upgrades extract ran past its closing marker" >&2
		echo "      it swallowed the rest of the script" >&2
		exit 1
		;;
esac
case "$block" in
	*'upgrade_switch'*) : ;;
	*)
		echo "FAIL  the automatic-upgrades extract does not set upgrade_switch" >&2
		echo "      its markers moved; the block below would report nothing" >&2
		exit 1
		;;
esac

# Prepare a runnable copy: the config directory moves into the sandbox, and
# the template placeholder is filled in. The earlier `apt-get install -y -qq
# unattended-upgrades` substitution has been removed because that branch no
# longer exists; the sed is left in place so older copies of the script
# still run the assertion below without it failing to construct.
prepare() { # $1 = sandbox
	mkdir -p "$1/apt.conf.d"
	{ extract_output_layer; extract_block; } \
		| sed 's|apt-get install -y -qq unattended-upgrades|true|' \
		| sed 's|@PRODUCT@|testproduct|g' \
		> "$1/block.sh"
}

# APT_CONF_D is the script's own override, so the block runs unmodified in the
# part that matters. `apt-config` is stubbed because this test is about what
# the installer does with what it reads, not about apt reading it.
#
# $2 is what the stubbed `apt-config` prints. Without a stub the function
# returns "unknown" -- honest, but it means the path that distinguishes on
# from off is never exercised and every assertion below would pass with it
# deleted.
run_block() { # $1=sandbox  $2=apt-config dump output
	mkdir -p "$1/bin"
	{
		echo '#!/bin/sh'
		echo "cat <<'DUMP'"
		printf '%s\n' "${2-}"
		echo 'DUMP'
	} > "$1/bin/apt-config"
	chmod +x "$1/bin/apt-config"
	( cd "$1" && PATH="$1/bin:$PATH" APT_CONF_D="$1/apt.conf.d" sh block.sh 2>&1 )
}

# What apt-config dump returns for each scenario. Each stub has the right
# APT::Periodic keys (or not) for the switch state and the right
# Unattended-Upgrade::* entries for the archive state. The stubs are what
# the function reads, so this is also what makes the test reproducible
# against a sandbox that never installs unattended-upgrades.

ON_PERIODIC='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'

OFF_PERIODIC='APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";'

ALLOWED='Unattended-Upgrade::Allowed-Origins:: "Glyndor:stable";'
PATTERN='Unattended-Upgrade::Origins-Pattern:: "origin=Glyndor";'
BLACKLIST_LINE='Unattended-Upgrade::Package-Blacklist:: "testproduct";'

ON_WITH_ALLOW="$ALLOWED
$ON_PERIODIC"
ON_WITH_PATTERN="$PATTERN
$ON_PERIODIC"
ON_WITH_BLACKLIST="$ALLOWED
$BLACKLIST_LINE
$ON_PERIODIC"
ON_WITH_WRONG_ORIGIN='Unattended-Upgrade::Allowed-Origins:: "Debian:bookworm-security";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Update-Package-Lists "1";'

OFF_WITH_ALLOW="$ALLOWED
$OFF_PERIODIC"

NO_PERIODIC_ALLOW="$ALLOWED"

# A file whose contents are the real APT::Periodic keys, used to match the
# dump stub for the switch-on scenarios. The file is what the operator
# edits; the dump stub is what the function reads; both must agree for the
# test to exercise the on-allowed path. In a sandbox the file does not
# matter on its own -- the stub decides everything the function sees -- but
# keeping both sides matching makes the test fail loud if the script ever
# goes back to reading the file directly.
write_on_file() { # $1=sandbox
	cat > "$1/apt.conf.d/20auto-upgrades" <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
}

write_off_file() { # $1=sandbox
	cat > "$1/apt.conf.d/20auto-upgrades" <<'CONF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
CONF
}

# --- #1: a switch at "0" is reported as off, not as on ----------------------
#
# The defect. A 20auto-upgrades with APT::Periodic::Unattended-Upgrade "0"
# was being reported as "already on" because the shortcut looked at the
# file's existence and not at what it said. The new function reads the
# value and the screen says so.

s="$WORK/switchoff"
prepare "$s"
write_off_file "$s"
out="$(run_block "$s" "$OFF_WITH_ALLOW")"
check "a switch at \"0\" is not reported as already on" "0" \
	"$(printf '%s' "$out" | grep -c 'already on, left alone')"
check "and the screen says it is switched off" "1" \
	"$(printf '%s' "$out" | grep -q 'switched off, left alone' && echo 1 || echo 0)"
check "and the script did not silently write a 1 on top of it" "0" \
	"$([ -f "$s/apt.conf.d/20auto-upgrades" ] \
		&& grep -q 'Unattended-Upgrade "1"' "$s/apt.conf.d/20auto-upgrades" \
		&& echo 1 || echo 0)"
check "and did not drop a 52glyndor-safety file" "0" \
	"$([ -f "$s/apt.conf.d/52glyndor-safety" ] && echo 1 || echo 0)"

# --- #2: a switch at "1" is reported as on ----------------------------------
#
# The positive case. APT::Periodic::Unattended-Upgrade "1" plus the
# archive in the allowlist -> "already on, left alone".

s="$WORK/switchon"
prepare "$s"
write_on_file "$s"
out="$(run_block "$s" "$ON_WITH_ALLOW")"
check "a switch at \"1\" with the archive allowed is reported as on" "1" \
	"$(printf '%s' "$out" | grep -q 'already on, left alone' && echo 1 || echo 0)"
check "and does not warn about the archive" "0" \
	"$(printf '%s' "$out" | grep -c 'not for this archive')"
check "and does not write on top of the operator's file" "1" \
	"$(grep -q 'Unattended-Upgrade "1"' "$s/apt.conf.d/20auto-upgrades" && echo 1 || echo 0)"

# --- #3: no APT::Periodic keys at all -> unknown ----------------------------
#
# A machine with no APT::Periodic keys can run unattended-upgrades on a
# systemd timer, and the timer is not visible to apt-config. A binary
# on/off check would have called this machine "off" and started writing
# settings the operator did not ask for; the new function returns unknown.

s="$WORK/noperiodic"
prepare "$s"
out="$(run_block "$s" "$NO_PERIODIC_ALLOW")"
check "with no APT::Periodic keys the screen does not claim on" "0" \
	"$(printf '%s' "$out" | grep -c 'already on, left alone')"
check "and does not claim off" "0" \
	"$(printf '%s' "$out" | grep -c 'switched off, left alone')"
check "and says it could not determine" "1" \
	"$(printf '%s' "$out" | grep -q 'could not determine' && echo 1 || echo 0)"
check "and writes nothing on the operator's behalf" "0" \
	"$([ -f "$s/apt.conf.d/20auto-upgrades" ] && echo 1 || echo 0)"
check "and does not drop a 52glyndor-safety file" "0" \
	"$([ -f "$s/apt.conf.d/52glyndor-safety" ] && echo 1 || echo 0)"

# --- #4: a placeholder file is the same as no keys --------------------------
#
# The fixture the old tests used was `printf 'set by the operator'` -- text
# apt does not parse. The new function reads apt-config dump, ignores that
# text, and returns unknown.

s="$WORK/placeholder"
prepare "$s"
printf 'set by the operator' > "$s/apt.conf.d/20auto-upgrades"
out="$(run_block "$s" "$NO_PERIODIC_ALLOW")"
check "a placeholder file is not read as on" "0" \
	"$(printf '%s' "$out" | grep -c 'already on, left alone')"
check "and is reported as could not determine" "1" \
	"$(printf '%s' "$out" | grep -q 'could not determine' && echo 1 || echo 0)"

# --- #5+: the switch is on -- what about the archive? (#194) ----------------
#
# The archive-side matrix. The fixtures used to take a placeholder file as
# evidence that the operator had the switch set, which pinned the file-
# existence shortcut on the switch. They now write a real switch-on file
# and use a matching dump stub. What is exercised here is the archive
# side, not the switch.

s="$WORK/allowed"
prepare "$s"
write_on_file "$s"
out="$(run_block "$s" "$ON_WITH_ALLOW")"
check "with the archive allowed, it says settings were left alone" "1" \
	"$(printf '%s' "$out" | grep -q 'already on, left alone' && echo 1 || echo 0)"
check "and warns about nothing" "0" \
	"$(printf '%s' "$out" | grep -c 'not for this archive')"

# The second spelling. The unattended-upgrades README says Allowed-Origins
# OR Origins-Pattern, so a check that knows only the one our keyring writes
# is right on every machine we configured and wrong on the operator's --
# wrong in the loud direction, telling someone who is covered that they
# are not.
s="$WORK/pattern"
prepare "$s"
write_on_file "$s"
out="$(run_block "$s" "$ON_WITH_PATTERN")"
check "Origins-Pattern counts as allowed, not just Allowed-Origins" "1" \
	"$(printf '%s' "$out" | grep -q 'already on, left alone' && echo 1 || echo 0)"

# The case this exists for: switch on, allowlist opted out. The file is a
# conffile so an operator who emptied it keeps their empty version through
# every reinstall, and the old message called that "already on, left alone".
s="$WORK/noorigin"
prepare "$s"
write_on_file "$s"
out="$(run_block "$s" "$ON_WITH_WRONG_ORIGIN")"
check "with the switch on but the archive not allowed, it says so" "1" \
	"$(printf '%s' "$out" | grep -q 'not for this archive' && echo 1 || echo 0)"
check "and does not claim things were left in order" "0" \
	"$(printf '%s' "$out" | grep -c 'already on, left alone')"
check "and says what it means for the product" "1" \
	"$(printf '%s' "$out" | grep -q 'will not be upgraded on its own' && echo 1 || echo 0)"

# Origin allowed, package vetoed. A third way to be frozen that reading the
# allowlist alone reports as healthy.
s="$WORK/blacklist"
prepare "$s"
write_on_file "$s"
out="$(run_block "$s" "$ON_WITH_BLACKLIST")"
check "a blacklisted product is reported even with the origin allowed" "1" \
	"$(printf '%s' "$out" | grep -q 'is blacklisted' && echo 1 || echo 0)"
check "and it does not claim things were left in order" "0" \
	"$(printf '%s' "$out" | grep -c 'already on, left alone')"

# --- #6: an unreadable apt-config means unknown, full stop ------------------
#
# A machine whose apt-config cannot be read is not "on" and not "off", and
# the operator should know that. The earlier test asserted a green tick
# "Automatic security upgrades on" -- the default arm that reports success
# without measuring anything -- and is replaced with the unknown message.

s="$WORK/aptbroken"
prepare "$s"
mkdir -p "$s/bin"
printf '#!/bin/sh\nexit 1\n' > "$s/bin/apt-config"; chmod +x "$s/bin/apt-config"
out="$( cd "$s" && PATH="$s/bin:$PATH" APT_CONF_D="$s/apt.conf.d" sh block.sh 2>&1 )"
check "an unreadable apt-config does not claim on" "0" \
	"$(printf '%s' "$out" | grep -c 'already on, left alone')"
check "and does not claim off" "0" \
	"$(printf '%s' "$out" | grep -c 'switched off, left alone')"
check "and warns about nothing the install could not measure" "0" \
	"$(printf '%s' "$out" | grep -c 'not for this archive')"
check "and says it could not determine" "1" \
	"$(printf '%s' "$out" | grep -q 'could not determine' && echo 1 || echo 0)"

# --- #7: dpkg presence is irrelevant ---------------------------------------
#
# The original regression. A machine with the unattended-upgrades package
# present took the do-nothing branch even with the switch off, because the
# shortcut asked `dpkg -s` instead of asking apt. Both sandboxes below have
# no APT::Periodic keys; they differ only in whether a `dpkg` binary is on
# PATH, and the outcome must be identical.

for variant in with-dpkg without-dpkg; do
	s="$WORK/dpkg-$variant"
	prepare "$s"
	if [ "$variant" = with-dpkg ]; then
		mkdir -p "$s/bin"
		printf '#!/bin/sh\nexit 0\n' > "$s/bin/dpkg"
		chmod +x "$s/bin/dpkg"
	fi
	( cd "$s" && PATH="$s/bin:$PATH" APT_CONF_D="$s/apt.conf.d" sh block.sh >/dev/null 2>&1 )
	check "with no APT::Periodic keys, no file is written regardless of dpkg ($variant)" "0" \
		"$([ -f "$s/apt.conf.d/20auto-upgrades" ] && echo 1 || echo 0)"
done

# --- #8: the block must not look at the file by name ------------------------
#
# The narrow assertion for the new fix. Any reintroduction of a shortcut
# that asks "does the file exist" puts the file-existence trap back, and
# the operator who wrote "0" inside is told their machine is on.

check "the block does not test 20auto-upgrades by file existence" "0" \
	"$(printf '%s' "$block" | grep -cE '\[ +-f[^]]*20auto-upgrades')"

# --- #9: the block still does not consult dpkg ------------------------------
#
# The earlier regression. Kept so a future shortcut that reverts to "is the
# package installed" fails the suite rather than slipping through.

check "the block still asks about the switch, not about the package" "0" \
	"$(printf '%s' "$block" | grep -c 'dpkg -s')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
