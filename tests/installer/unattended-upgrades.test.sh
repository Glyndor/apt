#!/usr/bin/env bash
#
# What the installer tells the operator about automatic upgrades.
#
# Keeping Glyndor packages current is the job of glyndor-upgrade.timer, which
# the keyring package installs and switches on. The installer does not touch
# the machine's own APT::Periodic schedule. What it does here is install the
# engine the timer runs when that is missing, and report the truth:
#
#   timer enabled          -> "daily, Glyndor packages only"
#   timer disabled         -> "switched off, left alone" and how to undo it
#   no systemd             -> a note, no claim
#   unit not installed     -> a note, no claim
#   engine cannot install  -> "engine not installed", in red
#   product blacklisted    -> "on, but <product> is blacklisted", in red
#
# This runs the real block out of the shipped script rather than a copy, with
# systemd's directory redirected into a sandbox and systemctl, apt-config and
# the engine stubbed, so what is asserted is what the installer does.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/installer/install-template.sh"
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
# drift from what ships.
extract_block() {
	awk '/^# --- automatic upgrades ---/,/^# --- end automatic upgrades ---/' "$SCRIPT"
}
extract_output_layer() {
	awk '/^# --- output ---/,/^# --- end output ---/' "$SCRIPT"
}

output_layer="$(extract_output_layer)"
case "$output_layer" in
	*"step()"*) : ;;
	*)
		echo "FAIL  the output layer in $SCRIPT does not define step()" >&2
		exit 1
		;;
esac
# The layer must have stopped before the block: if it swallowed it, the block
# would be defined twice and run twice.
case "$output_layer" in
	*'upgrade_switch=""'*)
		echo "FAIL  the output layer extract ran past its closing marker" >&2
		exit 1
		;;
esac
block="$(extract_block)"
case "$block" in
	*'upgrade_switch'*) : ;;
	*)
		echo "FAIL  could not find the automatic-upgrades block in $SCRIPT" >&2
		exit 1
		;;
esac
case "$block" in
	*'glyndor_timer_state() {'*)
		echo "FAIL  the block extract ran past its closing marker" >&2
		exit 1
		;;
esac

# $1 = sandbox, $2 = enabled|disabled|missing|nosystemd, $3 = apt-config dump,
# $4 = engine: present|absent|uninstallable
run_case() {
	local s="$1" state="$2" dump="$3" engine="${4:-present}"
	mkdir -p "$s/bin" "$s/systemd"
	[ "$state" = nosystemd ] && rmdir "$s/systemd"
	{
		extract_output_layer
		extract_block
	} | sed -e 's|apt-get install -y -qq unattended-upgrades|touch engine-installed|' \
		-e "s|/run/systemd/system|$s/systemd|g" \
		-e 's|@PRODUCT@|testproduct|g' > "$s/block.sh"
	# The engine is found by name on PATH. "absent" makes it appear only once the
	# stubbed install has run; "uninstallable" makes it never appear.
	case "$engine" in
		absent) sed -i 's|command -v unattended-upgrade >/dev/null 2>&1|[ -f engine-installed ]|' "$s/block.sh" ;;
		uninstallable) sed -i 's|command -v unattended-upgrade >/dev/null 2>&1|false|; s|touch engine-installed|false|' "$s/block.sh" ;;
	esac
	printf '%s\n' "$dump" > "$s/dump.txt"
	printf '#!/bin/sh\ncat "%s/dump.txt"\n' "$s" > "$s/bin/apt-config"
	# shellcheck disable=SC2016 # $1 is meant to expand in the stub, not here
	printf '#!/bin/sh\n[ "$1" = is-enabled ] && echo "%s" && [ "%s" = enabled ]\n' "$state" "$state" > "$s/bin/systemctl"
	printf '#!/bin/sh\nexit 0\n' > "$s/bin/unattended-upgrade"
	chmod +x "$s/bin/"*
	( cd "$s" && PATH="$s/bin:$PATH" sh block.sh 2>&1 )
}

says() { printf '%s' "$1" | grep -q "$2" && echo 1 || echo 0; }

NOBL='APT::Periodic::Unattended-Upgrade "0";'

# --- the timer is on -----------------------------------------------------------
out="$(run_case "$WORK/on" enabled "$NOBL")"
check "an enabled timer is reported as daily, Glyndor only" "1" "$(says "$out" 'daily, Glyndor packages only')"
check "and the machine's own APT::Periodic \"0\" does not matter" "0" "$(says "$out" 'switched off')"
check "and the engine was already there, so it is not installed" "0" \
	"$([ -f "$WORK/on/engine-installed" ] && echo 1 || echo 0)"

# --- the operator switched it off ------------------------------------------------
out="$(run_case "$WORK/off" disabled "$NOBL")"
check "a disabled timer is reported as switched off" "1" "$(says "$out" 'switched off, left alone')"
check "and says how to switch it on" "1" "$(says "$out" 'systemctl enable --now glyndor-upgrade.timer')"
check "and does not claim it is on" "0" "$(says "$out" 'daily, Glyndor')"

# --- no systemd, or an older keyring ------------------------------------------------
out="$(run_case "$WORK/nosd" nosystemd "$NOBL")"
check "without systemd it says there is no timer" "1" "$(says "$out" 'not running systemd')"
check "and does not claim it is on" "0" "$(says "$out" 'daily, Glyndor')"
out="$(run_case "$WORK/missing" missing "$NOBL")"
check "with the unit not installed it says so" "1" "$(says "$out" 'timer is not installed')"
check "and does not claim it is on" "0" "$(says "$out" 'daily, Glyndor')"

# --- the engine -------------------------------------------------------------------------
out="$(run_case "$WORK/noeng" enabled "$NOBL" absent)"
check "a missing engine is installed" "1" "$([ -f "$WORK/noeng/engine-installed" ] && echo 1 || echo 0)"
check "and the timer is then reported as on" "1" "$(says "$out" 'daily, Glyndor packages only')"
out="$(run_case "$WORK/noinst" enabled "$NOBL" uninstallable)"
check "an engine that cannot be installed is reported" "1" "$(says "$out" 'engine not installed')"
check "and nothing claims the product stays current" "0" "$(says "$out" 'daily, Glyndor')"

# --- the operator vetoed the product ------------------------------------------------------
for entry in 'testproduct' '^testproduct$' '^testproduct'; do
	out="$(run_case "$WORK/bl" enabled "Unattended-Upgrade::Package-Blacklist:: \"$entry\";")"
	check "a blacklist entry \"$entry\" is reported" "1" "$(says "$out" 'is blacklisted')"
	check "and the green line is withheld ($entry)" "0" "$(says "$out" 'daily, Glyndor')"
done
out="$(run_case "$WORK/blother" enabled 'Unattended-Upgrade::Package-Blacklist:: "someotherpkg";')"
check "a blacklist naming another package does not matter" "1" "$(says "$out" 'daily, Glyndor packages only')"
out="$(run_case "$WORK/blbad" enabled 'Unattended-Upgrade::Package-Blacklist:: "[";')"
check "an unparsable blacklist entry is not read as clear" "0" "$(says "$out" 'daily, Glyndor')"
check "and the screen says it could not be read" "1" "$(says "$out" 'blacklist could not be read')"

# --- the block must not go back to asking dpkg or the schedule -------------------------------
check "the block does not ask dpkg whether the package is installed" "0" \
	"$(printf '%s' "$block" | grep -c 'dpkg -s')"
check "the block does not write apt configuration" "0" \
	"$(printf '%s' "$block" | grep -c 'apt.conf.d')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
