#!/usr/bin/env bash
#
# scripts/verify/upgrade-floor.sh is what .github/workflows/distro-floor.yml runs inside a fresh
# container to ask whether a machine that has the version of a product before the served one ends on
# the served one, with the product answering, after `apt-get install --only-upgrade`. It runs after
# every publication where nobody watches, so each way it can say "yes" wrongly has to be shown here
# to say no: an upgrade that did not happen, one that landed on the wrong version, a product that
# stopped starting, a dpkg left half configured, a file that is not what the package shipped, and
# the case where there was no earlier version to start from, which is not a pass.
#
# The script is run as it ships, with every tool it calls replaced by a stub on PATH that keeps the
# state of a package in a folder: the installer puts the served version in place, apt-get purges and
# installs, and each case chooses what the stubs answer. No network, no container, no root.
#
# Not covered, and not coverable without a container: the real apt, the real maintainer scripts.
# Requires: bash, sh.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/upgrade-floor.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

command -v sh >/dev/null 2>&1 || { echo "NOTE  sh is missing, so nothing below could run. Not a pass."; exit 1; }

PRODUCT=upg-probe
S="$WORK/state"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CURL_FAIL:-}" ] && exit 22
out=""; prev=""
for arg in "$@"; do [ "$prev" = "-o" ] && out="$arg"; prev="$arg"; done
cp "$STATE/installer.sh" "$out"
STUB
cat > "$WORK/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
case "$*" in
	*Conffiles*) cat "$STATE/conffiles.now" 2>/dev/null; exit 0 ;;
esac
[ -f "$STATE/installed" ] && cat "$STATE/installed" || exit 1
STUB
cat > "$WORK/bin/dpkg-deb" <<'STUB'
#!/usr/bin/env bash
# dpkg-deb -f <file> <Field>: the fixture packages are text files of `Field: value` lines.
sed -n "s/^$3: //p" "$2" | head -n 1
STUB
cat > "$WORK/bin/dpkg" <<'STUB'
#!/usr/bin/env bash
case "$1" in
	--compare-versions)
		a="$2"; op="$3"; b="$4"
		if [ "$a" = "$b" ]; then cmp=0; elif [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" = "$a" ]; then cmp=-1; else cmp=1; fi
		case "$op" in lt) [ "$cmp" = -1 ] ;; gt) [ "$cmp" = 1 ] ;; *) exit 2 ;; esac ;;
	--audit) printf '%s' "${STUB_AUDIT:-}" ;;
	-V) printf '%s' "${STUB_VERIFY:-}" ;;
esac
STUB
cat > "$WORK/bin/apt-cache" <<'STUB'
#!/usr/bin/env bash
case "$1" in
	madison) printf '%s' "${STUB_MADISON:-}" ;;
	policy) echo "  Candidate: ${STUB_CANDIDATE:-$(cat "$STATE/served")}" ;;
esac
STUB
cat > "$WORK/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
# apt-get update / install -y -qq curl ca-certificates / purge / install --allow-downgrades <p>=<v> or <file> / install --only-upgrade <p>
args=" $* "
case "$args" in
	*" update "*) exit 0 ;;
	*" purge "*) [ -n "${STUB_PURGE_FAIL:-}" ] && exit 100; rm -f "$STATE/installed"; exit 0 ;;
	*" --only-upgrade "*)
		echo "Setting up the upgrade"
		[ -n "${STUB_UPGRADE_FAIL:-}" ] && { echo "E: could not upgrade"; exit 100; }
		echo "${STUB_UPGRADE_TO:-$(cat "$STATE/served")}" > "$STATE/installed"
		[ -n "${STUB_BREAK_AFTER_UPGRADE:-}" ] && touch "$STATE/broken"
		cp "$STATE/conffiles.after" "$STATE/conffiles.now" 2>/dev/null
		exit 0 ;;
	*" --allow-downgrades "*)
		[ -n "${STUB_INSTALL_FAIL:-}" ] && exit 100
		last="${*: -1}"
		if [ -f "$last" ]; then sed -n 's/^Version: //p' "$last" | head -n 1 > "$STATE/installed"; else echo "${last#*=}" > "$STATE/installed"; fi
		[ -n "${STUB_PREVIOUS_LANDS_AS:-}" ] && echo "$STUB_PREVIOUS_LANDS_AS" > "$STATE/installed"
		cp "$STATE/conffiles.before" "$STATE/conffiles.now" 2>/dev/null
		exit 0 ;;
	*) exit 0 ;;
esac
STUB
cat > "$WORK/bin/$PRODUCT" <<'STUB'
#!/usr/bin/env bash
[ -f "$STATE/broken" ] && exit 126
[ -f "$STATE/broken-before" ] && [ "$(cat "$STATE/installed")" = "$(cat "$STATE/previous")" ] && exit 126
exit 0
STUB
chmod +x "$WORK"/bin/*

package() { # <path> <package> <version>
	printf 'Package: %s\nVersion: %s\n' "$2" "$3" > "$1"
}

# Run the script as it ships. $1 = served version, $2 = previous deb path or empty. The case sets the STUB_*
# variables it needs on the command line.
run_upgrade() {
	local served="$1" deb="$2"
	rm -rf "$S"; mkdir -p "$S"
	echo "$served" > "$S/served"
	printf '#!/bin/sh\necho "%s installed" \nexit 0\n' "$PRODUCT" > "$S/installer.sh"
	: > "$S/conffiles.before"; : > "$S/conffiles.after"
	[ -n "${INSTALLER_BODY:-}" ] && printf '%s\n' "$INSTALLER_BODY" > "$S/installer.sh"
	[ -z "${INSTALLER_BODY:-}" ] && printf '#!/bin/sh\necho "%s" > "%s/installed"\nexit 0\n' "$served" "$S" > "$S/installer.sh"
	[ -n "${PREVIOUS_VERSION:-}" ] && echo "$PREVIOUS_VERSION" > "$S/previous"
	[ -n "${CONF_BEFORE:-}" ] && printf '%s\n' "$CONF_BEFORE" > "$S/conffiles.before"
	[ -n "${CONF_AFTER:-}" ] && printf '%s\n' "$CONF_AFTER" > "$S/conffiles.after"
	[ -n "${BROKEN_BEFORE:-}" ] && touch "$S/broken-before"
	STATE="$S" PATH="$WORK/bin:/usr/bin:/bin" sh "$SCRIPT" "$PRODUCT" ${deb:+"$deb"} 2>&1
}
say() { printf '%s' "$1" | grep -c -- "$2"; }

package "$WORK/prev.deb" "$PRODUCT" "1.0.0"
package "$WORK/same.deb" "$PRODUCT" "2.0.0"
package "$WORK/newer.deb" "$PRODUCT" "3.0.0"
package "$WORK/other.deb" "another-package" "1.0.0"
ARCHIVE="$PRODUCT | 2.0.0 | https://apt.glyndor.net stable/main amd64 Packages"$'\n'
DEBIAN="$PRODUCT | 0.5.0 | http://deb.debian.org/debian trixie/main amd64 Packages"$'\n'

# --- the archive keeps only the served version: the version before comes from the release --------

out="$(run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "an upgrade from the package of the release before passes" "0" "$rc"
check "and says the archive keeps no earlier version and where the one used came from" "1" "$(say "$out" 'archive keeps no version of upg-probe below 2.0.0, as it serves the latest only')"
check "and says what it went from and to" "1" "$(say "$out" 'went from 1.0.0 (the release before) to 2.0.0')"

# A distribution package of the same name and a lower version is not a version the archive keeps.
out="$(STUB_MADISON="$DEBIAN" run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a lower version that only the distribution indexes is not taken for the archive's" "1" "$(say "$out" 'the archive keeps no version')"

# --- the archive still indexes an older version: it starts from that one -------------------------

out="$(STUB_MADISON="$ARCHIVE$(printf '%s | 1.5.0 | https://apt.glyndor.net stable/main amd64 Packages\n' "$PRODUCT")" run_upgrade 2.0.0 "")"; rc=$?
check "an older version the archive indexes is the starting point when no package is given" "0" "$rc"
check "and says it came from the archive" "1" "$(say "$out" 'went from 1.5.0 (the archive) to 2.0.0')"

# --- nothing earlier exists: not a pass -----------------------------------------------------------

out="$(run_upgrade 2.0.0 "")"; rc=$?
check "no earlier version anywhere is exit 3" "3" "$rc"
check "and says that it was not verified" "1" "$(say "$out" 'NOT VERIFIED')"

# --- a starting point that is not one --------------------------------------------------------------

out="$(run_upgrade 2.0.0 "$WORK/same.deb")"; rc=$?
check "a previous package that is not below the served version fails" "1" "$rc"
check "and says so" "1" "$(say "$out" 'not below the served 2.0.0')"
out="$(run_upgrade 2.0.0 "$WORK/other.deb")"; rc=$?
check "a package of another product fails" "1" "$rc"
check "and says so" "1" "$(say "$out" 'is not a package of upg-probe')"
out="$(run_upgrade 2.0.0 "$WORK/missing.deb")"; rc=$?
check "a previous package that does not exist fails" "1" "$rc"
check "and says so" "1" "$(say "$out" 'does not exist')"

# --- the installer ----------------------------------------------------------------------------------

out="$(INSTALLER_BODY=$'#!/bin/sh\necho "no route"\nexit 1' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a published installer that fails stops it, printing the installer's output" "1" "$rc"
check "and says there is nothing to upgrade from" "1" "$(say "$out" 'installer failed, so there is nothing to upgrade from')"
out="$(INSTALLER_BODY=$'#!/bin/sh\nexit 0' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "an installer that exits 0 and installs nothing fails" "1" "$rc"
check "and says the product is not installed" "1" "$(say "$out" 'is not installed')"
out="$(STUB_CURL_FAIL=1 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "an installer that cannot be downloaded fails" "1" "$rc"
check "and names the URL" "1" "$(say "$out" 'could not download https://apt.glyndor.net/install/upg-probe')"

# --- the starting point is where it says it is ------------------------------------------------------

out="$(STUB_PREVIOUS_LANDS_AS=9.9.9 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a package that installs as another version than the one asked fails" "1" "$rc"
check "and says which" "1" "$(say "$out" 'is 9.9.9, not the 1.0.0 that was installed')"
out="$(BROKEN_BEFORE=1 PREVIOUS_VERSION=1.0.0 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a starting version that does not start fails, since the upgrade would prove nothing" "1" "$rc"
check "and says so" "1" "$(say "$out" 'does not start before the upgrade')"

out="$(STUB_PURGE_FAIL=1 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a product that cannot be removed to put the version before in its place fails" "1" "$rc"
check "and says so" "1" "$(say "$out" 'could not remove upg-probe')"
out="$(STUB_INSTALL_FAIL=1 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a previous package that cannot be installed fails" "1" "$rc"
check "and names the package" "1" "$(say "$out" 'could not install .*prev.deb')"
out="$(STUB_INSTALL_FAIL=1 STUB_MADISON="$ARCHIVE$(printf '%s | 1.5.0 | https://apt.glyndor.net stable/main amd64 Packages\n' "$PRODUCT")" run_upgrade 2.0.0 "")"; rc=$?
check "a previous version of the archive that cannot be installed fails" "1" "$rc"
check "and names the version" "1" "$(say "$out" 'could not install upg-probe 1.5.0 from the archive')"

# --- the upgrade ---------------------------------------------------------------------------------------

out="$(STUB_CANDIDATE=2.1.0 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "an apt that offers another version than the served one fails" "1" "$rc"
check "and says which it offers" "1" "$(say "$out" 'apt offers upg-probe 2.1.0, not the served 2.0.0')"
out="$(STUB_UPGRADE_FAIL=1 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "an upgrade that apt refuses fails, printing its output" "1" "$rc"
check "and says which command failed" "1" "$(say "$out" 'install --only-upgrade upg-probe failed')"
check "and shows the output of apt" "1" "$(say "$out" 'E: could not upgrade')"
out="$(STUB_UPGRADE_TO=1.0.0 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "an upgrade that leaves the previous version in place fails" "1" "$rc"
check "and says what it is now" "1" "$(say "$out" 'after the upgrade upg-probe is 1.0.0, not the served 2.0.0')"
out="$(STUB_BREAK_AFTER_UPGRADE=1 run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a product that stops starting after the upgrade fails" "1" "$rc"
check "and says so" "1" "$(say "$out" 'does not start after the upgrade')"
out="$(STUB_AUDIT='upg-probe: half configured' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a dpkg left with a package half configured fails" "1" "$rc"
check "and says so" "1" "$(say "$out" 'not fully configured')"
out="$(STUB_VERIFY='??5??????  /usr/bin/upg-probe' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a file that is not what the package shipped fails" "1" "$rc"
check "and says so, naming the file" "1" "$(say "$out" '/usr/bin/upg-probe')"
out="$(STUB_VERIFY='missing     /usr/share/man/man1/upg-probe.1.gz' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a manual page the image does not carry is not a file that differs" "0" "$rc"

# --- the configuration files -----------------------------------------------------------------------------

out="$(CONF_BEFORE='d41d8cd98f00b204e9800998ecf8427e  /etc/upg-probe/a.conf' CONF_AFTER='d41d8cd98f00b204e9800998ecf8427e  /etc/upg-probe/a.conf' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "configuration files that are the same before and after pass" "0" "$rc"
check "and say so" "1" "$(say "$out" 'are the same before and after')"
out="$(CONF_BEFORE='aaaa  /etc/upg-probe/a.conf' CONF_AFTER='bbbb  /etc/upg-probe/b.conf' run_upgrade 2.0.0 "$WORK/prev.deb")"; rc=$?
check "a configuration file that moves is shown in the log" "1" "$(say "$out" 'changed in the upgrade')"
check "and the upgrade still passes, since a move is the package's to decide" "0" "$rc"
out="$(run_upgrade 2.0.0 "$WORK/prev.deb")"
check "a package with no configuration files says so" "1" "$(say "$out" 'owns no configuration file under /etc')"

# --- the workflow runs this script after each publication, for the three products and the three images ---

check "the workflow runs upgrade-floor.sh inside the container" "1" "$(grep -c 'sh /upgrade-floor.sh' "$HERE/.github/workflows/distro-floor.yml")"
check "after the publication workflow" "1" "$(grep -c 'workflows: \[Publish apt repository\]' "$HERE/.github/workflows/distro-floor.yml")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
