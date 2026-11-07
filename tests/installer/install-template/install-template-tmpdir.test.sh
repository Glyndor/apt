#!/usr/bin/env bash
# The installer verifies the signature of the downloaded package and then runs
# dpkg on it. If the directory holding it could be replaced by another user in
# between, dpkg would install bytes nobody verified while the installer said
# "Package signature verified". Crypto is stubbed here: the cases test WHERE the
# package lives and WHETHER the file dpkg receives is the file that was checked.
#
# Requires: dpkg-deb, python3 is not needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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

"$HERE/scripts/build/build-installers.sh" "$WORK/install" testpkg >/dev/null || exit 1
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/pkg/DEBIAN" "$WORK/pkg/usr/share/keyrings"
printf 'Package: glyndor-archive-keyring\nVersion: 1\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: tmpdir fixture\n' > "$WORK/pkg/DEBIAN/control"
echo fixture-key > "$WORK/pkg/usr/share/keyrings/glyndor.gpg"
dpkg-deb --root-owner-group --build "$WORK/pkg" "$WORK/keyring.deb" >/dev/null || exit 1
echo fixture-signature > "$WORK/keyring.deb.asc"
for cmd in id apt-get dpkg gpg testpkg unattended-upgrade; do
	cat > "$WORK/bin/$cmd" <<'SH'
#!/bin/sh
name=${0##*/}
echo "$name $*" >> "$WORK/state/commands"
case "$name" in
	id) echo 0 ;;
	gpg)
		case "$*" in
			*--show-keys*) printf 'pub:::::::::\nfpr:::::::::9ADF04EA8C3139CDB67303CFA6705C2EA153F3D6:\n' ;;
			*--verify*)
				# The test plays the attacker: on the FIRST verification it
				# changes the file that was just verified.
				if [ -f "$WORK/state/swap" ] && [ ! -f "$WORK/state/swapped" ]; then
					for last; do :; done
					printf 'attacker' >> "$last"; : > "$WORK/state/swapped"
				fi ;;
		esac ;;
	dpkg) echo "$*" > "$WORK/state/dpkg-arg"; cp "$WORK/pkg/usr/share/keyrings/glyndor.gpg" "$WORK/state/keyring" ;;
	testpkg) echo 'testpkg version 1' ;;
esac
exit 0
SH
	chmod +x "$WORK/bin/$cmd"
done

cat > "$WORK/bin/stat" <<'STATSTUB'
#!/bin/sh
# The installer pretends to be root, so every directory it examines is reported
# as owned by root. STUB_OWNER_PATH and STUB_OWNER_UID name one directory owned
# by someone else; STUB_STAT_FAIL makes the owner lookup fail. Anything but the
# owner lookup goes to the real stat.
if [ "$1" = "-c" ] && [ "$2" = "%u" ]; then
	[ -z "${STUB_STAT_FAIL:-}" ] || exit 1
	if [ -n "${STUB_OWNER_PATH:-}" ] && [ "$3" = "$STUB_OWNER_PATH" ]; then echo "$STUB_OWNER_UID"; else echo 0; fi
	exit 0
fi
exec @REALSTAT@ "$@"
STATSTUB
sed -i "s|@REALSTAT@|$(command -v stat)|" "$WORK/bin/stat"; chmod +x "$WORK/bin/stat"

# run <tmpdir>: the installer through a pipe with TMPDIR set (or unset when empty).
run() {
	rm -f "$WORK/state/commands" "$WORK/state/keyring" "$WORK/state/dpkg-arg" "$WORK/state/swapped"
	if [ -n "$1" ]; then
		env -i PATH="$WORK/bin:$PATH" HOME="$WORK" WORK="$WORK" TMPDIR="$1" STUB_OWNER_PATH="${STUB_OWNER_PATH:-}" STUB_OWNER_UID="${STUB_OWNER_UID:-}" STUB_STAT_FAIL="${STUB_STAT_FAIL:-}" KEYRING_URL="file://$WORK/keyring.deb" \
			/bin/sh < "$WORK/install/testpkg" > "$WORK/out" 2>&1
	else
		env -i PATH="$WORK/bin:$PATH" HOME="$WORK" WORK="$WORK" STUB_OWNER_PATH="${STUB_OWNER_PATH:-}" STUB_OWNER_UID="${STUB_OWNER_UID:-}" STUB_STAT_FAIL="${STUB_STAT_FAIL:-}" KEYRING_URL="file://$WORK/keyring.deb" \
			/bin/sh < "$WORK/install/testpkg" > "$WORK/out" 2>&1
	fi
	rc=$?
}
reached_dpkg() { [ -f "$WORK/state/dpkg-arg" ] && echo 1 || echo 0; }
said() { grep -qF -- "$1" "$WORK/out" && echo 1 || echo 0; }

mkdir -p "$WORK/t"; chmod 700 "$WORK/t"

mkdir -m 700 "$WORK/t/private"
run "$WORK/t/private"
check "control: a private TMPDIR installs" "0" "$rc"
check "and dpkg is reached" "1" "$(reached_dpkg)"

# dpkg must receive the private copy that was compared with the verified bytes,
# not the file that was downloaded and verified in the shared work directory.
check "dpkg receives the private copy, not the downloaded file" "1" \
	"$(grep -q '/install/glyndor-archive-keyring.deb' "$WORK/state/dpkg-arg" && echo 1 || echo 0)"

mkdir -m 777 "$WORK/t/shared"; chmod 777 "$WORK/t/shared"
run "$WORK/t/shared"
check "a TMPDIR others can write to, with no sticky bit, is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message names the missing sticky bit" "1" "$(said 'sticky')"
check "and the message names the directory" "1" "$(said "$WORK/t/shared")"
check "and dpkg is never reached" "0" "$(reached_dpkg)"

mkdir -m 775 "$WORK/t/group"; chmod 775 "$WORK/t/group"
run "$WORK/t/group"
check "a TMPDIR the group can write to, with no sticky bit, is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

mkdir -m 1777 "$WORK/t/sticky"; chmod 1777 "$WORK/t/sticky"
run "$WORK/t/sticky"
check "a shared TMPDIR with the sticky bit, like /tmp, is accepted" "0" "$rc"
check "and dpkg is reached" "1" "$(reached_dpkg)"

mkdir -m 777 "$WORK/t/open"; mkdir -m 700 "$WORK/t/open/inner"; chmod 777 "$WORK/t/open"
run "$WORK/t/open/inner"
check "a private TMPDIR under a world-writable ancestor with no sticky bit is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message names the ancestor" "1" "$(said "$WORK/t/open")"

mkdir -m 700 "$WORK/t/with space"
run "$WORK/t/with space"
check "a TMPDIR with a space installs" "0" "$rc"
check "and dpkg receives a path inside that directory" "1" "$(grep -qF "$WORK/t/with space/" "$WORK/state/dpkg-arg" 2>/dev/null && echo 1 || echo 0)"

mkdir -m 700 "$WORK/t/umask"
( umask 000; run "$WORK/t/umask"; exit "$rc" ); rc=$?
check "an installer run under umask 000 still installs" "0" "$rc"

# The file dpkg receives must be the file whose signature was checked.
: > "$WORK/state/swap"
run "$WORK/t/private"
check "a package changed after it was verified is not installed" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and dpkg is never reached" "0" "$(reached_dpkg)"
check "and the message says the package changed" "1" "$(said 'changed between')"
rm -f "$WORK/state/swap"

run "$WORK/t/private"
check "control: without the swap it installs again" "0" "$rc"

# --- who owns the directories on the path -------------------------------------
# Mode bits say who MAY write; the owner can always rename. As root with a
# TMPDIR under a directory another user owns, that user can swap the work
# directory after the last verification, so the owner of every directory on the
# path has to be root. The stat stub reports root for every directory except the
# one a case names.
mkdir -m 700 "$WORK/t/owned"
STUB_OWNER_PATH="$WORK/t/owned" STUB_OWNER_UID=4242 run "$WORK/t/owned"
check "a TMPDIR owned by another user is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and dpkg is never reached" "0" "$(reached_dpkg)"
check "and the message names the directory and the uid" "1" "$(said "owned by uid 4242")"
check "and says the owner could replace the package" "1" "$(said 'could replace the verified package')"
mkdir -p "$WORK/t/parent/child"; chmod 700 "$WORK/t/parent" "$WORK/t/parent/child"
STUB_OWNER_PATH="$WORK/t/parent" STUB_OWNER_UID=4242 run "$WORK/t/parent/child"
check "a TMPDIR under a directory owned by another user is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message names the ancestor" "1" "$(said "$WORK/t/parent is owned by uid 4242")"
STUB_STAT_FAIL=1 run "$WORK/t/private"
check "an owner that cannot be read is refused, not assumed safe" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message says the owner could not be determined" "1" "$(said 'could not determine the owner')"
run "$WORK/t/private"
check "control: every directory owned by root installs" "0" "$rc"
# Control: the installer without the owner check. The hostile TMPDIR then installs.
python3 -I - "$WORK/install/testpkg" "$WORK/install/testpkg-noowner" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = '\t\trequire_safe_dir_owner "$_dir"\n'
assert old in s
open(sys.argv[2], "w").write(s.replace(old, "", 1))
PY
env -i PATH="$WORK/bin:$PATH" HOME="$WORK" WORK="$WORK" TMPDIR="$WORK/t/owned" STUB_OWNER_PATH="$WORK/t/owned" STUB_OWNER_UID=4242 KEYRING_URL="file://$WORK/keyring.deb" \
	/bin/sh < "$WORK/install/testpkg-noowner" > "$WORK/out" 2>&1
check "control: without the owner check the hostile TMPDIR installs" "0" "$?"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
