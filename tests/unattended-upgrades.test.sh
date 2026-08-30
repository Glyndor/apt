#!/usr/bin/env bash
#
# The installer's last act is to switch automatic security upgrades on, and the
# README promises it. That block had no test, and it died without anyone
# noticing why it would: it used to decide by asking `dpkg -s
# unattended-upgrades`, which answers "is the package here" rather than "is the
# switch off". `apt-get install @PRODUCT@` runs twelve lines earlier and this
# script passes no `--no-install-recommends`, so a product that merely
# recommends unattended-upgrades installs it too. The test then reads true on a
# machine that had never seen the package, the configuring branch becomes
# unreachable, and the installer prints "leaving its settings alone" and exits 0
# having switched nothing on. Reported from Glyndor/podup, whose `debian/control`
# on develop now depends on the package outright.
#
# Two files are at stake, not one. `52glyndor-safety` -- the file that stops an
# unattended upgrade rebooting a server on its own -- is written in the same
# branch and went with it.
#
# This runs the real block out of the shipped script rather than a copy, with
# `/etc/apt/apt.conf.d` redirected into a temporary tree and `apt-get` stubbed,
# so what is asserted is what the installer does rather than what it looks like.
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
	awk '/^if \[ -f "\$APT_CONF_D"\/20auto-upgrades \]/,/^fi$/' "$SCRIPT"
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

# Prepare a runnable copy: the config directory moves into the sandbox, the
# package install is stubbed to succeed without touching the machine, and the
# template placeholder is filled in.
prepare() { # $1 = sandbox
	mkdir -p "$1/apt.conf.d"
	{ extract_output_layer; extract_block; } \
		| sed 's|apt-get install -y -qq unattended-upgrades|true|' \
		| sed 's|@PRODUCT@|testproduct|g' \
		> "$1/block.sh"
}

# APT_CONF_D is the script's own override, so the block runs unmodified in the
# part that matters. Only the package install is stubbed, because this test is
# about what gets written and not about apt.
run_block() { ( cd "$1" && APT_CONF_D="$1/apt.conf.d" sh block.sh 2>&1 ); }

# --- the switch is absent: both files must be written ---------------------
#
# This is the case that was broken. The package being present is irrelevant now,
# and the case is written that way on purpose: the sandbox never installs it.

s="$WORK/absent"
prepare "$s"
out="$(run_block "$s")"
check "with the switch absent, 20auto-upgrades is written" "1" \
	"$([ -f "$s/apt.conf.d/20auto-upgrades" ] && echo 1 || echo 0)"
check "and 52glyndor-safety is written with it" "1" \
	"$([ -f "$s/apt.conf.d/52glyndor-safety" ] && echo 1 || echo 0)"
check "and it says what it did" "1" \
	"$(printf '%s' "$out" | grep -q 'no automatic reboot' && echo 1 || echo 0)"

# The reboot setting is the reason 52glyndor-safety exists. Asserting the file
# is present would pass on an empty file.
check "and the safety file turns automatic reboots off" "1" \
	"$(grep -q 'Automatic-Reboot "false"' "$s/apt.conf.d/52glyndor-safety" && echo 1 || echo 0)"
check "and switches the periodic upgrade on" "1" \
	"$(grep -q 'Unattended-Upgrade "1"' "$s/apt.conf.d/20auto-upgrades" && echo 1 || echo 0)"

# --- the switch is already on: nothing may be touched ---------------------

s="$WORK/present"
prepare "$s"
printf 'set by the operator\n' > "$s/apt.conf.d/20auto-upgrades"
out="$(run_block "$s")"
check "with the switch already on, the operator's file is left alone" "set by the operator" \
	"$(cat "$s/apt.conf.d/20auto-upgrades")"
check "and no safety file is dropped on top of their settings" "0" \
	"$([ -f "$s/apt.conf.d/52glyndor-safety" ] && echo 1 || echo 0)"
check "and it says it left things alone" "1" \
	"$(printf '%s' "$out" | grep -q 'already on, left alone' && echo 1 || echo 0)"

# --- the decision must not depend on whether the package is installed -----
#
# The regression this file exists for. Before, a machine with the package
# present took the do-nothing branch even with the switch off. Both sandboxes
# below have the switch off; they differ only in whether `dpkg -s` would
# succeed, and the outcome must be identical.

for variant in with-package without-package; do
	s="$WORK/$variant"
	prepare "$s"
	if [ "$variant" = with-package ]; then
		mkdir -p "$s/bin"
		printf '#!/bin/sh\nexit 0\n' > "$s/bin/dpkg"
		chmod +x "$s/bin/dpkg"
	fi
	( cd "$s" && PATH="$s/bin:$PATH" APT_CONF_D="$s/apt.conf.d" sh block.sh >/dev/null 2>&1 )
	check "the switch is written regardless of the package ($variant)" "1" \
		"$([ -f "$s/apt.conf.d/20auto-upgrades" ] && echo 1 || echo 0)"
done

# --- the block must not consult dpkg at all -------------------------------
#
# The narrow assertion that pins the fix. Any reintroduction of a package
# presence test, however it is spelled, puts `dpkg` back in this block.

check "the block asks about the switch, not about the package" "0" \
	"$(printf '%s' "$block" | grep -c 'dpkg -s')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
