#!/usr/bin/env bash
# Exercise timer enable/disable and recovery across package lifecycle events.
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

# --- maintainer scripts -------------------------------------------------------

mkdir -p "$WORK/sbin" "$WORK/state"
# A systemctl that remembers: enable and disable change the state that is-enabled
# reads, so the cases below can tell a timer the package switched off from one the
# operator did.
cat > "$WORK/sbin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/systemctl.log"
case "\$1" in
	enable) [ -f "$WORK/enable-fails" ] && exit 1; echo enabled > "$WORK/unit-state"
		case "\$*" in *--now*) echo active > "$WORK/active-state" ;; esac ;;
	disable) echo disabled > "$WORK/unit-state"
		case "\$*" in *--now*) echo inactive > "$WORK/active-state" ;; esac ;;
	stop) echo inactive > "$WORK/active-state" ;;
	is-enabled) [ "\$(cat "$WORK/unit-state" 2>/dev/null)" = enabled ]; exit \$? ;;
	is-active) [ "\$(cat "$WORK/active-state" 2>/dev/null)" = active ]; exit \$? ;;
esac
exit 0
STUB
chmod +x "$WORK/sbin/systemctl"

# The scripts hard-code /run/systemd/system and /var/lib; both move into the
# sandbox so this never touches the machine running the test.
mkdir -p "$WORK/run/systemd/system"
# The postinst also looks at the trust anchor (the key directory and the apt
# source). Those move into the sandbox too, with a source file that is exactly
# what the package ships, or the result would depend on whether the machine
# running the test has the package installed.
mkdir -p "$WORK/keyrings" "$WORK/sources"
chmod 755 "$WORK/keyrings" "$WORK/sources"
sed "s|/usr/share/keyrings|$WORK/keyrings|g" "$HERE/keyring/glyndor.sources" > "$WORK/sources/glyndor.sources"
sandboxed() { # $1 = maintainer script name
	sed -e "s|/run/systemd/system|$WORK/run/systemd/system|g" \
		-e "s|/var/lib/glyndor-archive-keyring|$WORK/state|g" \
		-e "s|/usr/share/keyrings|$WORK/keyrings|g" \
		-e "s|/etc/apt/sources.list.d|$WORK/sources|g" \
		"$HERE/keyring/upgrade/maintainer-$1" > "$WORK/$1"
}
for s in postinst prerm postrm; do sandboxed "$s"; done
post() { PATH="$WORK/sbin:$PATH" sh "$WORK/postinst" "$@"; }
pre() { PATH="$WORK/sbin:$PATH" sh "$WORK/prerm" "$@"; }
gone() { PATH="$WORK/sbin:$PATH" sh "$WORK/postrm" "$@"; }
reset() { rm -rf "$WORK/state" "$WORK/systemctl.log" "$WORK/unit-state" "$WORK/active-state" "$WORK/enable-fails"; mkdir -p "$WORK/state"; }
unit() { cat "$WORK/unit-state" 2>/dev/null || echo none; }
logged() { grep -c "$1" "$WORK/systemctl.log" 2>/dev/null || true; }

reset
post configure
check "a first install enables and starts the timer" "enabled" "$(unit)"
check "and leaves the marker" "1" "$([ -f "$WORK/state/timer-offered" ] && echo 1 || echo 0)"
check "after reloading systemd, so the new units are known" "1" \
	"$(grep -n 'daemon-reload' "$WORK/systemctl.log" | head -1 | cut -d: -f1)"

: > "$WORK/systemctl.log"
post configure 1.0.0+pkg20260101000000
check "a later upgrade does not enable it again" "0" "$(logged 'enable')"
check "but still reloads systemd, because it can install new units" "1" "$(logged 'daemon-reload')"

reset
post configure 1.0.0+pkg20250101000000
check "a machine from before the timer existed gets it on upgrade" "enabled" "$(unit)"

reset
rm -rf "$WORK/run/systemd"
post configure
check "without systemd nothing is started" "0" "$([ -f "$WORK/systemctl.log" ] && echo 1 || echo 0)"
check "and no marker is written, so a later configure tries again" "0" \
	"$([ -f "$WORK/state/timer-offered" ] && echo 1 || echo 0)"
mkdir -p "$WORK/run/systemd/system"

reset
: > "$WORK/enable-fails"
post configure
check "an enable that fails leaves no marker" "0" "$([ -f "$WORK/state/timer-offered" ] && echo 1 || echo 0)"

# What the package switches off it switches back on; what the operator disabled stays.
reset
post configure
pre deconfigure
check "deconfiguring the package switches the timer off" "disabled" "$(unit)"
post configure
check "configuring it again switches the timer back on" "enabled" "$(unit)"
check "and forgets that it had suspended it" "0" \
	"$([ -f "$WORK/state/suspended-by-package" ] && echo 1 || echo 0)"

# A restore that fails keeps its mark, so the next configure tries again.
reset
post configure
pre deconfigure
: > "$WORK/enable-fails"
post configure
check "a restore that fails keeps the mark" "1" \
	"$([ -f "$WORK/state/suspended-by-package" ] && echo 1 || echo 0)"
rm -f "$WORK/enable-fails"
post configure
check "and the next configure switches the timer back on" "enabled" "$(unit)"

reset
post configure
pre remove
post abort-remove
check "a removal that is aborted gives the timer back" "enabled" "$(unit)"

reset
post configure
echo disabled > "$WORK/unit-state"
pre deconfigure
post configure
check "a timer the operator disabled stays disabled across deconfigure and configure" "disabled" "$(unit)"
post abort-remove
check "and across an aborted removal" "disabled" "$(unit)"

# `systemctl disable` without --now leaves the timer running; removing the
# package must still stop it, and must not promise to turn it back on.
reset
post configure
echo disabled > "$WORK/unit-state"
pre remove
check "a timer disabled without --now but still running is stopped on removal" "inactive" \
	"$(cat "$WORK/active-state" 2>/dev/null)"
check "and nothing is remembered to turn it back on" "0" \
	"$([ -f "$WORK/state/suspended-by-package" ] && echo 1 || echo 0)"

reset
post configure
pre remove
gone remove
check "removing the package clears what it remembered" "0" "$([ -d "$WORK/state" ] && echo 1 || echo 0)"
reset
post configure
gone purge
check "and so does purging it, so a reinstall offers the timer again" "0" "$([ -d "$WORK/state" ] && echo 1 || echo 0)"

for f in postinst prerm postrm; do
	check "maintainer-$f is valid shell" "0" "$(sh -n "$HERE/keyring/upgrade/maintainer-$f"; echo $?)"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
