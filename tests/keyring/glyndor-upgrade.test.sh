#!/usr/bin/env bash
#
# The Glyndor upgrade timer is the thing that keeps every package from this
# archive current, so what it does is pinned here with the engine stubbed:
#
#   * the config it hands unattended-upgrade whitelists exactly what apt would
#     change to upgrade the installed Glyndor packages, strictly;
#   * names with "." or "+" in them are matched literally;
#   * with no Glyndor index it fails instead of running unrestricted;
#   * the maintainer scripts switch the timer on once, and leave an operator's
#     `systemctl disable` alone on every later upgrade.
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

# --- the upgrade script -------------------------------------------------------

mkdir -p "$WORK/bin" "$WORK/lists" "$WORK/run"
# apt-get -s prints the plan in $WORK/plan.txt; anything else does nothing.
# dpkg-query reports what is "installed" from $WORK/installed.txt.
cat > "$WORK/bin/apt-get" <<STUB
#!/bin/sh
case "\$*" in
	*indextargets*) ls "$WORK"/lists/* 2>/dev/null ;;
	*--only-upgrade*) [ -f "$WORK/sim-fails" ] && { echo "E: Unable to lock the administration directory" >&2; exit 100; }
		cat "$WORK/plan.txt" 2>/dev/null; echo "\$*" > "$WORK/sim-args" ;;
esac
exit 0
STUB
# apt-helper cat-file reads whichever form apt kept the index in.
cat > "$WORK/bin/apt-helper" <<'STUB'
#!/bin/sh
[ "$1" = cat-file ] || exit 2
case "$2" in
	*.gz) zcat "$2" ;;
	*) cat "$2" ;;
esac
STUB
chmod +x "$WORK/bin/apt-helper"
# Like the real one in the one respect that matters here: \${Package} is the bare
# name, \${binary:Package} keeps the ":arch" of a foreign-architecture package.
cat > "$WORK/bin/dpkg-query" <<STUB
#!/bin/sh
fmt=""
while [ \$# -gt 0 ]; do
	case "\$1" in -f) fmt="\$2"; shift ;; -f*) fmt="\${1#-f}" ;; esac
	shift
done
case "\$fmt" in
	*binary:Package*) cat "$WORK/installed.txt" 2>/dev/null ;;
	*) sed 's/:[a-z0-9-]*\$//' "$WORK/installed.txt" 2>/dev/null ;;
esac
STUB
cat > "$WORK/bin/unattended-upgrade" <<STUB
#!/bin/sh
cp "\$APT_CONFIG" "$WORK/seen.conf"
echo "\$APT_CONFIG" >> "$WORK/seen.paths"
stat -c %a "\$APT_CONFIG" > "$WORK/mode"
STUB
chmod +x "$WORK/bin/apt-get" "$WORK/bin/dpkg-query" "$WORK/bin/unattended-upgrade"

run_upgrade() {
	rm -f "$WORK/seen.conf"
	env PATH="$WORK/bin:$PATH" GNUPGHOME=/nonexistent \
		GLYNDOR_APT_HELPER="$WORK/bin/apt-helper" GLYNDOR_RUN_DIR="$WORK/run" \
		GLYNDOR_UNATTENDED="$WORK/bin/unattended-upgrade" \
		sh "$HERE/keyring/upgrade/glyndor-upgrade" 2>&1
}
ran() { [ -f "$WORK/seen.conf" ] && echo 1 || echo 0; }

run_upgrade >/dev/null; rc=$?
check "with no Glyndor index the script fails" "1" "$rc"
check "and does not run the engine unrestricted" "0" "$(ran)"

cat > "$WORK/lists/apt.glyndor.net_dists_stable_main_binary-amd64_Packages" <<'PKG'
Package: podup
Version: 1

Package: epistle
Version: 1

Package: glyndor-archive-keyring
Version: 1

Package: libfoo.bar+baz
Version: 1
PKG
cp "$WORK/lists/apt.glyndor.net_dists_stable_main_binary-amd64_Packages" \
	"$WORK/lists/apt.glyndor.net_dists_stable_main_binary-arm64_Packages"

printf 'un  epistle\n' > "$WORK/installed.txt"
run_upgrade >/dev/null; rc=$?
check "with no Glyndor package installed there is nothing to do" "0" "$rc"
check "and the engine does not run" "0" "$(ran)"

printf 'ii  podup\nii  libfoo.bar+baz\nun  epistle\n' > "$WORK/installed.txt"
: > "$WORK/plan.txt"
run_upgrade >/dev/null; rc=$?
check "when everything is current the script succeeds" "0" "$rc"
check "and the engine does not run" "0" "$(ran)"
check "only installed Glyndor packages are asked about" "1" \
	"$(grep -c 'install podup libfoo.bar+baz$' "$WORK/sim-args")"

# A hostile name must not reach the config, and it must not read as "current":
# an empty plan after filtering would hide an upgrade that was never attempted.
# The index is signed, so this is the second lock; it still has to hold alone.
index="$WORK/lists/apt.glyndor.net_dists_stable_main_binary-amd64_Packages"
cp "$index" "$WORK/index.good"
printf 'ii  podup\n' > "$WORK/installed.txt"
printf 'Inst podup [1] (2 stable)\nInst x";y (1 trixie)\n' > "$WORK/plan.txt"
run_upgrade >"$WORK/run.out" 2>&1; rc=$?
check "a plan entry with a quote makes the script fail" "1" "$rc"
check "and the engine does not run" "0" "$(ran)"
check "and the journal names the entry" "1" "$(grep -c 'invalid package name in the upgrade plan: x' "$WORK/run.out")"

printf 'Inst podup [1] (2 stable)\nInst Bad (1 trixie)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null 2>&1; rc=$?
check "an uppercase name in the plan fails too" "1" "$rc"

printf 'Inst podup [1] (2 stable)\nInst libfoo:i386 (1 trixie)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null 2>&1; rc=$?
check "a foreign-architecture name is accepted" "0" "$rc"

printf '\nPackage: evil"; }; X "\nVersion: 1\n' >> "$index"
run_upgrade >"$WORK/run.out" 2>&1; rc=$?
check "a hostile name in the index makes the script fail" "1" "$rc"
check "and says which list it was in" "1" "$(grep -c 'invalid package name in the Glyndor index' "$WORK/run.out")"
cp "$WORK/index.good" "$index"
printf 'ii  podup\nii  libfoo.bar+baz\n' > "$WORK/installed.txt"

# apt-get -s failing is not "everything is current".
printf 'ii  podup\n' > "$WORK/installed.txt"
: > "$WORK/plan.txt"
touch "$WORK/sim-fails"
run_upgrade >/dev/null; rc=$?
check "when apt cannot plan the upgrade the script fails" "1" "$rc"
check "and the engine does not run" "0" "$(ran)"
rm -f "$WORK/sim-fails"
printf 'ii  podup\nii  libfoo.bar+baz\n' > "$WORK/installed.txt"

# podup is upgraded and its new release needs podman, which is not installed.
printf 'Inst podup [1] (2 stable)\nInst podman (5.4 trixie)\nInst libfoo.bar+baz (2 stable)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null; rc=$?
check "with something to upgrade the script runs the engine" "0" "$rc"
check "and hands it a config" "1" "$(ran)"
conf="$(cat "$WORK/seen.conf" 2>/dev/null)"
check "the whitelist is strict" "1" \
	"$(printf '%s' "$conf" | grep -c 'Package-Whitelist-Strict "true"')"
check "an upgraded Glyndor package is whitelisted, anchored" "1" \
	"$(printf '%s' "$conf" | grep -cF '"^podup$";')"
check "a dependency the release needs is whitelisted too" "1" \
	"$(printf '%s' "$conf" | grep -cF '"^podman$";')"
check "a dot and a plus are matched literally" "1" \
	"$(printf '%s' "$conf" | grep -cF '"^libfoo[.]bar[+]baz$";')"
check "a Glyndor package that needs no upgrade is not named" "0" \
	"$(printf '%s' "$conf" | grep -cF 'glyndor-archive-keyring')"
check "nothing outside the plan is named" "0" \
	"$(printf '%s' "$conf" | grep -c 'curl')"
check "the archive's own origin is allowed" "1" \
	"$(printf '%s' "$conf" | grep -c 'Allowed-Origins { "Glyndor:stable"; }')"

# A compressed index, as apt keeps it with Acquire::GzipIndexes, is read too.
mkdir -p "$WORK/gz"
rm -f "$WORK/lists/"*
printf 'Package: podup\nVersion: 1\n' | gzip > "$WORK/lists/apt.glyndor.net_dists_stable_main_binary-amd64_Packages.gz"
printf 'ii  podup\n' > "$WORK/installed.txt"
printf 'Inst podup [1] (2 stable)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null; rc=$?
check "a compressed index is read" "0" "$rc"
check "and the engine runs on it" "1" "$(ran)"
# One unreadable index among readable ones fails the unit, it does not shrink the plan.
rm -f "$WORK/lists/"*
cp "$WORK/index.good" "$WORK/lists/apt.glyndor.net_a_Packages"
cp "$WORK/index.good" "$WORK/lists/apt.glyndor.net_b_Packages"
printf 'ii  podup\n' > "$WORK/installed.txt"
cat > "$WORK/bin/apt-helper" <<'STUB'
#!/bin/sh
case "$2" in *_b_Packages) exit 1 ;; esac
cat "$2"
STUB
run_upgrade >/dev/null; rc=$?
check "an unreadable index among readable ones is a failure" "1" "$rc"
check "and the engine does not run on the rest" "0" "$(ran)"
cat > "$WORK/bin/apt-helper" <<'STUB'
#!/bin/sh
[ "$1" = cat-file ] || exit 2
case "$2" in
	*.gz) zcat "$2" ;;
	*) cat "$2" ;;
esac
STUB
check "an index apt cannot read is a failure, not an empty plan" "1" \
	"$(rm -f "$WORK/lists/"*; : > "$WORK/lists/empty_Packages"; run_upgrade >/dev/null; echo $?)"

# A foreign-architecture package keeps its architecture all the way to apt, or
# apt looks at the native package of that name and reports the foreign one current.
cp "$WORK/index.good" "$index"
printf 'ii  podup:arm64\n' > "$WORK/installed.txt"
printf 'Inst podup:arm64 [1] (2 stable)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null; rc=$?
check "a foreign-architecture package is upgraded" "0" "$rc"
check "apt is asked about it with its architecture" "1" "$(grep -c 'install podup:arm64' "$WORK/sim-args")"
check "and the whitelist names it with its architecture" "1" "$(grep -cF '"^podup:arm64$";' "$WORK/seen.conf")"

# One private config per invocation, removed afterwards.
rm -f "$WORK/seen.paths"
printf 'ii  podup\n' > "$WORK/installed.txt"
printf 'Inst podup [1] (2 stable)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null
run_upgrade >/dev/null
check "each run hands the engine its own file" "2" "$(sort -u "$WORK/seen.paths" | wc -l)"
check "and leaves none behind" "0" "$(find "$WORK/run" -maxdepth 1 -name 'apt.conf*' | wc -l)"
check "the file is private to its owner" "600" "$(cat "$WORK/mode" 2>/dev/null)"

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
sandboxed() { # $1 = maintainer script name
	sed -e "s|/run/systemd/system|$WORK/run/systemd/system|g" \
		-e "s|/var/lib/glyndor-archive-keyring|$WORK/state|g" \
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
