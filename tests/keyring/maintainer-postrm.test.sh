#!/usr/bin/env bash
#
# Tests for keyring/upgrade/maintainer-postrm, which dpkg runs as root after the
# files are gone.
#
# Removing or purging forgets what the package remembered, so a reinstall offers
# the timer again instead of inheriting a marker from the old install. An
# upgrade must NOT forget it: the marker is what stops the timer being offered
# a second time to a machine that already answered.
#
# Requires: bash, sed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# A systemctl that remembers, so the cases can tell what the script asked for
# from what it left alone. The state and the systemd marker directory move into
# the sandbox: the scripts hard-code both.
mkdir -p "$WORK/sbin" "$WORK/state" "$WORK/run/systemd/system"
cat > "$WORK/sbin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/systemctl.log"
case "\$1" in
	disable) echo disabled > "$WORK/unit-state"
		case "\$*" in *--now*) echo inactive > "$WORK/active-state" ;; esac ;;
	stop) echo inactive > "$WORK/active-state" ;;
	is-enabled) [ "\$(cat "$WORK/unit-state" 2>/dev/null)" = enabled ]; exit \$? ;;
	is-active) [ "\$(cat "$WORK/active-state" 2>/dev/null)" = active ]; exit \$? ;;
esac
exit 0
STUB
chmod +x "$WORK/sbin/systemctl"

sandboxed() { # $1 = maintainer script name
	sed -e "s|/run/systemd/system|$WORK/run/systemd/system|g" \
		-e "s|/var/lib/glyndor-archive-keyring|$WORK/state|g" \
		"$HERE/keyring/upgrade/maintainer-$1" > "$WORK/$1"
}
run() { PATH="$WORK/sbin:$PATH" sh "$WORK/$1" "${@:2}"; }
reset() {
	rm -rf "$WORK/state" "$WORK/systemctl.log" "$WORK/unit-state" "$WORK/active-state"
	mkdir -p "$WORK/state" "$WORK/run/systemd/system"
}
has() { [ -e "$WORK/$1" ] && echo 1 || echo 0; }
sandboxed postrm

for action in remove purge; do
	reset
	touch "$WORK/state/timer-offered" "$WORK/state/suspended-by-package"
	run postrm "$action"
	check "$action forgets everything the package remembered" "0" "$(has state)"
	check "$action reloads systemd so the removed units are forgotten" "1" \
		"$(grep -c 'daemon-reload' "$WORK/systemctl.log")"
done

reset
touch "$WORK/state/timer-offered"
run postrm upgrade 1.0.0
check "an upgrade keeps what the package remembered" "1" "$(has state/timer-offered)"
check "and does not reload systemd" "0" "$(has systemctl.log)"

reset
touch "$WORK/state/timer-offered"
rm -rf "$WORK/run/systemd"
run postrm purge
check "without systemd the memory is still forgotten" "0" "$(has state)"
check "and systemctl is not asked for anything" "0" "$(has systemctl.log)"

reset
run postrm remove >/dev/null 2>&1
check "the script exits 0" "0" "$?"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
