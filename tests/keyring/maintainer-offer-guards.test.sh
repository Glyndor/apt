#!/usr/bin/env bash
# Guards of the maintainer scripts that the timer suite does not break: no timer
# offer over an apt source that is gone, no offer into a state directory that
# cannot be written, and the systemd reload after a removal. Each case runs a
# copy of the script with that one guard removed as its control, and the control
# behaves differently.
# shellcheck disable=SC2016 # the patterns name variables on purpose
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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

mkdir -p "$WORK/sbin" "$WORK/state" "$WORK/run/systemd/system" "$WORK/keyrings" "$WORK/sources"
chmod 755 "$WORK/keyrings" "$WORK/sources"
cat > "$WORK/sbin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/systemctl.log"
case "\$1" in
	enable) echo enabled > "$WORK/unit-state" ;;
	is-enabled) [ "\$(cat "$WORK/unit-state" 2>/dev/null)" = enabled ]; exit \$? ;;
esac
exit 0
STUB
chmod +x "$WORK/sbin/systemctl"
sed "s|/usr/share/keyrings|$WORK/keyrings|g" "$HERE/keyring/glyndor.sources" > "$WORK/sources/glyndor.sources"

sandbox() { # $1=script $2=output name  (and optional $3,$4 = text to replace and its replacement)
	python3 - "$HERE/keyring/upgrade/maintainer-$1" "$WORK/$2" "$WORK" "${3:-}" "${4:-}" <<'PY' || exit 1
import sys
src, dst, work, old, new = sys.argv[1:6]
s = open(src).read()
if old:
    assert old in s, "guard text not found: " + old
    s = s.replace(old, new)
for a, b in (("/run/systemd/system", work + "/run/systemd/system"),
             ("/var/lib/glyndor-archive-keyring", work + "/state"),
             ("/usr/share/keyrings", work + "/keyrings"),
             ("/etc/apt/sources.list.d", work + "/sources")):
    s = s.replace(a, b)
open(dst, "w").write(s)
PY
}
run() { PATH="$WORK/sbin:$PATH" sh "$WORK/$1" "${@:2}" 2>"$WORK/err"; }
reset() { chmod 755 "$WORK/state" 2>/dev/null; rm -rf "$WORK/state" "$WORK/systemctl.log" "$WORK/unit-state"; mkdir -p "$WORK/state"; }
unit() { cat "$WORK/unit-state" 2>/dev/null || echo none; }
logged() { [ -f "$WORK/systemctl.log" ] && { grep -c "$1" "$WORK/systemctl.log" || true; } || echo 0; }
said() { grep -cF "$1" "$WORK/err" || true; }

# --- the apt source is gone ---------------------------------------------------
sandbox postinst post
sandbox postinst post-cut 'echo "glyndor-archive-keyring: $sources_file is missing; this machine no longer receives the Glyndor archive, reinstall the package to restore it" >&2
		unsafe=1' 'echo "glyndor-archive-keyring: $sources_file is missing; this machine no longer receives the Glyndor archive, reinstall the package to restore it" >&2'
reset; rm -f "$WORK/sources/glyndor.sources"
run post configure
check 'with the apt source gone the timer is not offered' none "$(unit)"
check 'and the warning says the machine no longer receives the archive' 1 "$(said 'no longer receives the Glyndor archive')"
check 'and that the offer waits for the warnings to be fixed' 1 "$(said 'was not offered because of the warnings above')"
reset
run post-cut configure
check 'without the guard the timer is offered over a source that is gone' enabled "$(unit)"
sed "s|/usr/share/keyrings|$WORK/keyrings|g" "$HERE/keyring/glyndor.sources" > "$WORK/sources/glyndor.sources"

# --- the state directory cannot be written ------------------------------------
sandbox postinst post-nowrite '	if ! true 2>/dev/null > "$state/timer-offering"; then
		echo "glyndor-archive-keyring: $state is not writable; the upgrade timer was not offered" >&2
		return 0
	fi' '	true 2>/dev/null > "$state/timer-offering" || true'
reset; chmod 555 "$WORK/state"
if true 2>/dev/null > "$WORK/state/probe"; then
	echo "NOTE  a read-only directory is writable here (root?), so the case cannot run."
	exit 1
fi
run post configure
check 'a state directory that cannot be written gets no offer' none "$(unit)"
check 'and the warning says it is not writable' 1 "$(said 'is not writable')"
reset; chmod 555 "$WORK/state"
run post-nowrite configure
check 'without the guard the timer is enabled with nothing recording the offer' enabled "$(unit)"
chmod 755 "$WORK/state"

# --- removal reloads systemd --------------------------------------------------
sandbox postrm postrm
sandbox postrm postrm-cut '		if [ -d /run/systemd/system ]; then
			systemctl daemon-reload || true
		fi' '		:'
for action in remove purge; do
	reset
	run postrm "$action"
	check "after $action systemd is reloaded" 1 "$(logged daemon-reload)"
	reset
	run postrm-cut "$action"
	check "without the reload nothing tells systemd after $action" 0 "$(logged daemon-reload)"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
