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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
	*--only-upgrade*) [ -f "$WORK/sim-fails" ] && { echo "E: Unable to lock the administration directory" >&2; exit 100; }
		cat "$WORK/plan.txt" 2>/dev/null; echo "\$*" > "$WORK/sim-args" ;;
esac
exit 0
STUB
cat > "$WORK/bin/dpkg-query" <<STUB
#!/bin/sh
cat "$WORK/installed.txt" 2>/dev/null
STUB
cat > "$WORK/bin/unattended-upgrade" <<STUB
#!/bin/sh
cp "\$APT_CONFIG" "$WORK/seen.conf"
STUB
chmod +x "$WORK/bin/apt-get" "$WORK/bin/dpkg-query" "$WORK/bin/unattended-upgrade"

run_upgrade() {
	rm -f "$WORK/seen.conf"
	env PATH="$WORK/bin:$PATH" GNUPGHOME=/nonexistent \
		GLYNDOR_APT_LISTS="$WORK/lists" GLYNDOR_RUN_DIR="$WORK/run" \
		GLYNDOR_UNATTENDED="$WORK/bin/unattended-upgrade" \
		sh "$HERE/keyring/glyndor-upgrade" 2>&1
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

# A hostile name must not reach the config. The index is signed, so this is the
# second lock; it still has to hold on its own.
cat >> "$WORK/lists/apt.glyndor.net_dists_stable_main_binary-amd64_Packages" <<'PKG'

Package: evil"; }; Unattended-Upgrade::Package-Whitelist-Strict "false
Version: 1

Package: UPPER
Version: 1
PKG
printf 'ii  podup\n' > "$WORK/installed.txt"
printf 'Inst podup [1] (2 stable)\nInst x";y (1 trixie)\nInst Bad (1 trixie)\n' > "$WORK/plan.txt"
run_upgrade >/dev/null
conf="$(cat "$WORK/seen.conf" 2>/dev/null)"
check "a plan entry with a quote or an uppercase letter never reaches the config" "0" \
	"$(printf '%s' "$conf" | grep -c '[";]y\|Bad')"
check "the strict flag is still the only one set" "1" \
	"$(printf '%s' "$conf" | grep -c 'Package-Whitelist-Strict')"
check "and the legitimate package is still there" "1" "$(printf '%s' "$conf" | grep -cF '"^podup$";')"
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

# --- maintainer scripts -------------------------------------------------------

mkdir -p "$WORK/sbin" "$WORK/state"
cat > "$WORK/sbin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/systemctl.log"
STUB
chmod +x "$WORK/sbin/systemctl"

# The scripts hard-code /run/systemd/system and /var/lib; both move into the
# sandbox so this never touches the machine running the test.
mkdir -p "$WORK/run/systemd/system"
postinst="$WORK/postinst"
sed -e "s|/run/systemd/system|$WORK/run/systemd/system|g" \
	-e "s|/var/lib/glyndor-archive-keyring|$WORK/state|g" \
	"$HERE/keyring/maintainer-postinst" > "$postinst"

run_post() { PATH="$WORK/sbin:$PATH" sh "$postinst" "$@"; }

rm -f "$WORK/systemctl.log" "$WORK/state/timer-offered"
run_post configure
check "a first install enables and starts the timer" "1" \
	"$(grep -c 'enable --now glyndor-upgrade.timer' "$WORK/systemctl.log")"
check "and leaves the marker" "1" "$([ -f "$WORK/state/timer-offered" ] && echo 1 || echo 0)"

rm -f "$WORK/systemctl.log"
run_post configure 1.0.0+pkg20260101000000
check "a later upgrade does not enable it again" "0" \
	"$(grep -c enable < <(cat "$WORK/systemctl.log" 2>/dev/null))"

rm -f "$WORK/state/timer-offered" "$WORK/systemctl.log"
run_post configure 1.0.0+pkg20250101000000
check "a machine from before the timer existed gets it on upgrade" "1" \
	"$(grep -c 'enable --now glyndor-upgrade.timer' "$WORK/systemctl.log")"

rm -rf "$WORK/run/systemd" "$WORK/state/timer-offered" "$WORK/systemctl.log"
run_post configure
check "without systemd nothing is started" "0" \
	"$([ -f "$WORK/systemctl.log" ] && echo 1 || echo 0)"
check "and no marker is written, so a later configure tries again" "0" \
	"$([ -f "$WORK/state/timer-offered" ] && echo 1 || echo 0)"

mkdir -p "$WORK/run/systemd/system"
printf '#!/bin/sh\ncase "$*" in *enable*) exit 1 ;; esac\n' > "$WORK/sbin/systemctl"
rm -f "$WORK/state/timer-offered"
run_post configure
check "an enable that fails leaves no marker" "0" \
	"$([ -f "$WORK/state/timer-offered" ] && echo 1 || echo 0)"

for f in postinst prerm postrm; do
	check "maintainer-$f is valid shell" "0" "$(sh -n "$HERE/keyring/maintainer-$f"; echo $?)"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
