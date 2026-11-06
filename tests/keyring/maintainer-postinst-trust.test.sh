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

fresh; good_sources > "$WORK/t/sources/glyndor.sources"; chmod 777 "$WORK/t/keyrings"
mkdir -p "$WORK/fail"; printf '#!/bin/sh\nexit 1\n' > "$WORK/sbin/chmod"; chmod +x "$WORK/sbin/chmod"
post
check "a directory that cannot be closed fails the configure" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "with a message that says the trust anchor is not safe" "1" "$(said 'is not safe')"
rm -f "$WORK/sbin/chmod"

# --- the apt source file ------------------------------------------------------------
fresh; good_sources > "$WORK/t/sources/glyndor.sources"
post
check "control: an untouched source file is left alone" "0" "$(said 'restored')"

# The link points at a file with a CORRECT Signed-By line: it is the link, not
# the content, that must be refused, or a planted target can look fine and be
# swapped later.
fresh; good_sources > "$WORK/target"; ln -s "$WORK/target" "$WORK/t/sources/glyndor.sources"
good_sources > "$WORK/t/sources/glyndor.sources.dpkg-new" 2>/dev/null || true
post
check "a symlink where apt reads its source is replaced" "0" "$([ -L "$WORK/t/sources/glyndor.sources" ] && echo 1 || echo 0)"
check "by the package's own copy" "1" "$(cmp -s "$WORK/t/sources/glyndor.sources" <(good_sources) && echo 1 || echo 0)"
check "and the file the link pointed at is not touched" "$(good_sources | cksum)" "$(cksum < "$WORK/target")"

fresh; sed "s|^Signed-By: .*|Signed-By: /etc/apt/trusted.gpg.d/other.gpg|" <(good_sources) > "$WORK/t/sources/glyndor.sources"
good_sources > "$WORK/t/sources/glyndor.sources.dpkg-dist"
post
check "a Signed-By that points at another key is restored" "$WORK/t/keyrings/glyndor.gpg" \
	"$(sed -n 's/^Signed-By: *//p' "$WORK/t/sources/glyndor.sources")"
check "and the leftover copy is removed" "0" "$([ -e "$WORK/t/sources/glyndor.sources.dpkg-dist" ] && echo 1 || echo 0)"

fresh; sed "s|^Signed-By: .*|Signed-By: /etc/apt/trusted.gpg.d/other.gpg|" <(good_sources) > "$WORK/t/sources/glyndor.sources"
post
check "a wrong Signed-By with no copy of the package's file fails the configure" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and says how to recover" "1" "$(said 'reinstall the package')"

# --- the timer offer ---------------------------------------------------------------------
fresh; good_sources > "$WORK/t/sources/glyndor.sources"
post
check "a first install enables the timer" "enabled" "$(cat "$WORK/unit-state" 2>/dev/null)"
check "and records that it was offered" "1" "$([ -f "$WORK/t/state/timer-offered" ] && echo 1 || echo 0)"
check "leaving no half-finished marker" "0" "$([ -f "$WORK/t/state/timer-offering" ] && echo 1 || echo 0)"

fresh; good_sources > "$WORK/t/sources/glyndor.sources"; : > "$WORK/enable-fails"
post
check "an enable that fails leaves neither marker" "0" "$(find "$WORK/t/state" -type f | wc -l)"

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
