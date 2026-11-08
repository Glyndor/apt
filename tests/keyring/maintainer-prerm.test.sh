#!/usr/bin/env bash
#
# Tests for keyring/upgrade/maintainer-prerm, which dpkg runs as root on the
# customer's machine before a removal or deconfiguration.
#
# Two questions are answered separately and each has its own case: whether to
# remember a restore (only if the timer was enabled) and whether to stop the
# timer (even when the operator disabled it without --now and it is still
# running). Conflating them either loses the restore or leaves upgrades firing
# while the package is being removed.
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
sandboxed prerm

reset
echo enabled > "$WORK/unit-state"; echo active > "$WORK/active-state"
run prerm remove
check "remove with the timer enabled switches it off now" "disabled" "$(cat "$WORK/unit-state")"
check "remove remembers that the package did it" "1" "$(has state/suspended-by-package)"
check "remove stops the running timer" "inactive" "$(cat "$WORK/active-state")"

reset
echo enabled > "$WORK/unit-state"; echo active > "$WORK/active-state"
run prerm deconfigure
check "deconfigure behaves like remove" "1" "$(has state/suspended-by-package)"

reset
echo disabled > "$WORK/unit-state"; echo active > "$WORK/active-state"
run prerm remove
check "a timer the operator disabled but left running is stopped" "inactive" "$(cat "$WORK/active-state")"
check "and no restore is remembered for it" "0" "$(has state/suspended-by-package)"

reset
echo disabled > "$WORK/unit-state"; echo inactive > "$WORK/active-state"
run prerm remove
check "a timer that is already off is neither disabled nor stopped" "0" \
	"$(grep -cE '^(disable|stop)' "$WORK/systemctl.log" || true)"

reset
echo enabled > "$WORK/unit-state"; echo active > "$WORK/active-state"
run prerm upgrade 1.0.0
check "an upgrade does not touch the timer" "enabled" "$(cat "$WORK/unit-state")"
check "and remembers nothing" "0" "$(has state/suspended-by-package)"

reset
rm -rf "$WORK/run/systemd"
echo enabled > "$WORK/unit-state"
run prerm remove
check "without systemd nothing is asked of systemctl" "0" "$(has systemctl.log)"
check "and nothing is remembered" "0" "$(has state/suspended-by-package)"

reset
echo enabled > "$WORK/unit-state"
run prerm remove >/dev/null 2>&1
check "the script exits 0" "0" "$?"

# A state directory that cannot be written. A regular file where the directory
# should be fails mkdir and the redirection for root too, which a chmod would not.
reset
rm -rf "$WORK/state"; : > "$WORK/state"
echo enabled > "$WORK/unit-state"; echo active > "$WORK/active-state"
out="$(run prerm remove 2>&1)"; rc=$?
check "an unwritable state directory does not abort the removal" "0" "$rc"
check "the timer is still switched off now" "disabled" "$(cat "$WORK/unit-state")"
check "and stopped" "inactive" "$(cat "$WORK/active-state")"
check "and the warning says it is not writable" "1" "$(printf '%s' "$out" | grep -c 'is not writable')"

# The control: the two unguarded lines the script used to have abort it with set -e.
python3 -I - "$WORK/prerm" "$WORK/prerm-unguarded" <<'PY'
import sys
s = open(sys.argv[1]).read()
start = s.index('if ! { mkdir -p')
end = s.index('fi\n', start) + 3
assert start > 0
open(sys.argv[2], 'w').write(s[:start] + 'mkdir -p "$state"\n\t\t\t\t: > "$state/suspended-by-package"\n' + s[end:])
PY
reset
rm -rf "$WORK/state"; : > "$WORK/state"
echo enabled > "$WORK/unit-state"; echo active > "$WORK/active-state"
PATH="$WORK/sbin:$PATH" sh "$WORK/prerm-unguarded" remove >/dev/null 2>&1; rc=$?
check "without the guard the removal aborts and the timer stays on" "1 enabled" "$([ "$rc" -ne 0 ] && echo 1) $(cat "$WORK/unit-state")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
