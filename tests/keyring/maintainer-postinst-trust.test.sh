#!/usr/bin/env bash
#
# What the keyring package's postinst and upgrade timer check before they trust
# what is on the machine. A review planted these on a client and the package
# accepted every one: a symlink where apt reads its source, a Signed-By that
# points at a key the package does not ship (dpkg --force-confold keeps it, so a
# key rotation never takes effect), the two trust-anchor directories writable by
# anyone, a postinst killed halfway that turned the operator's opt-out back on,
# and dpkg-query failing, which the timer reported as "nothing to upgrade".
#
# The postinst runs in a sandbox: its paths are rewritten to a throwaway tree, as
# in tests/keyring/glyndor-upgrade.test.sh, so nothing touches the machine.
#
# Requires: sh, find, sed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fail=$((fail + 1))
	fi
}

PKG_SOURCES="$HERE/keyring/glyndor.sources"
mkdir -p "$WORK/sbin"
cat > "$WORK/sbin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/systemctl.log"
case "\$1" in
	enable) [ -f "$WORK/enable-fails" ] && exit 1; echo enabled > "$WORK/unit-state" ;;
	disable) echo disabled > "$WORK/unit-state" ;;
	is-enabled) [ "\$(cat "$WORK/unit-state" 2>/dev/null)" = enabled ]; exit \$? ;;
esac
exit 0
STUB
chmod +x "$WORK/sbin/systemctl"

# fresh: a clean sandbox tree and the postinst rewritten to live in it.
fresh() {
	rm -rf "$WORK/t"; mkdir -p "$WORK/t/keyrings" "$WORK/t/sources" "$WORK/t/state" "$WORK/t/run/systemd/system"
	chmod 755 "$WORK/t/keyrings" "$WORK/t/sources"
	rm -f "$WORK/systemctl.log" "$WORK/unit-state" "$WORK/enable-fails"
	: > "$WORK/t/keyrings/glyndor.gpg"
	sed -e "s|/run/systemd/system|$WORK/t/run/systemd/system|g" \
		-e "s|/var/lib/glyndor-archive-keyring|$WORK/t/state|g" \
		-e "s|/usr/share/keyrings|$WORK/t/keyrings|g" \
		-e "s|/etc/apt/sources.list.d|$WORK/t/sources|g" \
		"$HERE/keyring/upgrade/maintainer-postinst" > "$WORK/postinst"
}
post() { PATH="$WORK/sbin:$PATH" sh "$WORK/postinst" configure >"$WORK/out" 2>&1; rc=$?; }
said() { grep -qF -- "$1" "$WORK/out" && echo 1 || echo 0; }
good_sources() { sed "s|/usr/share/keyrings|$WORK/t/keyrings|g" "$PKG_SOURCES"; }
mode() { stat -c %a "$1"; }

# --- the directories that hold the trust anchor ----------------------------------
fresh; good_sources > "$WORK/t/sources/glyndor.sources"; chmod 777 "$WORK/t/keyrings"
post
check "a world-writable keyrings directory is closed" "755" "$(mode "$WORK/t/keyrings")"
check "and the configure still succeeds" "0" "$rc"
check "and says what it did" "1" "$(said 'was writable by group or others')"

fresh; good_sources > "$WORK/t/sources/glyndor.sources"; chmod 775 "$WORK/t/sources"
post
check "a group-writable sources directory is closed" "755" "$(mode "$WORK/t/sources")"

# A directory that cannot be closed is a warning, never a half-configured
# package: apt and unattended-upgrade would stop on a machine that was healthy.
fresh; good_sources > "$WORK/t/sources/glyndor.sources"; chmod 777 "$WORK/t/keyrings"
printf '#!/bin/sh\nexit 1\n' > "$WORK/sbin/chmod"; chmod +x "$WORK/sbin/chmod"
post
check "a directory that cannot be closed does NOT fail the configure" "0" "$rc"
check "and the warning says the trust anchor is not safe" "1" "$(said 'is not safe')"
rm -f "$WORK/sbin/chmod"

# A symlink is not followed: chmod would change the directory it points to.
fresh; good_sources > "$WORK/t/sources/glyndor.sources"; mkdir -m 777 "$WORK/elsewhere"; chmod 777 "$WORK/elsewhere"
rm -rf "$WORK/t/keyrings"; ln -s "$WORK/elsewhere" "$WORK/t/keyrings"
post
check "a symlinked directory is not chmodded through the link" "777" "$(mode "$WORK/elsewhere")"
check "and the configure succeeds" "0" "$rc"

# --- the apt source file: said, never rewritten --------------------------------------
fresh; good_sources > "$WORK/t/sources/glyndor.sources"
post
check "control: an untouched source file draws no warning" "0" "$(said 'is not what this package ships')"
check "and no warning about a missing one" "0" "$(said 'is missing')"

good_sum="$(good_sources | cksum)"
fresh; good_sources > "$WORK/target"; ln -s "$WORK/target" "$WORK/t/sources/glyndor.sources"
good_sources > "$WORK/t/sources/glyndor.sources.dpkg-new" 2>/dev/null || true
post
check "a symlink where apt reads its source is reported" "1" "$(said 'it is not a regular file')"
check "and left in place, not replaced behind the operator's back" "1" "$([ -L "$WORK/t/sources/glyndor.sources" ] && echo 1 || echo 0)"
check "and the configure succeeds" "0" "$rc"
check "and the warning names the package's own copy" "1" "$(said 'glyndor.sources.dpkg-new')"
check "and the file the link pointed at is not touched" "$good_sum" "$(cksum < "$WORK/target")"

fresh; sed "s|^Signed-By: .*|Signed-By: /etc/apt/trusted.gpg.d/other.gpg|" <(good_sources) > "$WORK/t/sources/glyndor.sources"
cp "$WORK/t/sources/glyndor.sources" "$WORK/custom"
post
check "a Signed-By that points at another key is reported" "1" "$(said "it trusts '/etc/apt/trusted.gpg.d/other.gpg'")"
check "with the consequence for a key rotation" "1" "$(said 'rotation of the archive key')"
check "and the operator's file is byte for byte as they left it" "$(cksum < "$WORK/custom")" "$(cksum < "$WORK/t/sources/glyndor.sources")"
check "and the configure succeeds" "0" "$rc"

fresh; good_sources > "$WORK/t/sources/glyndor.sources"; sed -i 's|^URIs: .*|URIs: https://mirror.example.net|' "$WORK/t/sources/glyndor.sources"
cp "$WORK/t/sources/glyndor.sources" "$WORK/custom"
post
check "a mirror the operator chose is not a warning" "0" "$(said 'is not what this package ships')"
check "and is not touched" "$(cksum < "$WORK/custom")" "$(cksum < "$WORK/t/sources/glyndor.sources")"

fresh
post
check "a missing source file is reported, since the machine stops receiving the archive" "1" "$(said 'is missing')"
check "and the configure still succeeds" "0" "$rc"

# --- the timer offer ---------------------------------------------------------------------
fresh; good_sources > "$WORK/t/sources/glyndor.sources"
post
check "a first install enables the timer" "enabled" "$(cat "$WORK/unit-state" 2>/dev/null)"
check "and records that it was offered" "1" "$([ -f "$WORK/t/state/timer-offered" ] && echo 1 || echo 0)"
check "leaving no half-finished marker" "0" "$([ -f "$WORK/t/state/timer-offering" ] && echo 1 || echo 0)"

fresh; good_sources > "$WORK/t/sources/glyndor.sources"; : > "$WORK/enable-fails"
post
check "an enable that fails leaves neither marker" "0" "$(find "$WORK/t/state" -type f | wc -l)"

# A state directory that cannot be written costs the offer, not the package.
fresh; good_sources > "$WORK/t/sources/glyndor.sources"; rm -rf "$WORK/t/state"; : > "$WORK/t/state"
post
check "a state directory that cannot be created does not fail the configure" "0" "$rc"
check "and the warning says the timer was not offered" "1" "$(said 'was not offered')"

# The postinst was killed after it started the offer: the marker says so, and the
# operator then switched the timer off. The next upgrade must not switch it on.
fresh; good_sources > "$WORK/t/sources/glyndor.sources"; : > "$WORK/t/state/timer-offering"; echo disabled > "$WORK/unit-state"
post
check "an interrupted offer does not undo the operator's opt-out" "disabled" "$(cat "$WORK/unit-state")"
check "and enable is never called" "0" "$(grep -c '^enable' "$WORK/systemctl.log" 2>/dev/null || true)"
check "and it says the timer was left as it is" "1" "$(said 'left as it is')"

fresh; good_sources > "$WORK/t/sources/glyndor.sources"; : > "$WORK/t/state/timer-offering"; echo enabled > "$WORK/unit-state"
post
check "an interrupted offer whose timer is on is recorded as offered" "1" "$([ -f "$WORK/t/state/timer-offered" ] && echo 1 || echo 0)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
