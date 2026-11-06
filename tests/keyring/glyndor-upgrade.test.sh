#!/usr/bin/env bash
#
# The Glyndor upgrade timer is the thing that keeps every package from this
# archive current, so what it does is pinned here with the engine stubbed:
#
#   * the config it hands unattended-upgrade whitelists exactly what apt would
#     change to upgrade the installed Glyndor packages, strictly;
#   * names with "." or "+" in them are matched literally;
#   * with no Glyndor index it fails instead of running unrestricted;
#   * indexes from other origins are never read.
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
# Model indextargets selectors; without Origin, Debian's indexes are visible too.
# -o consumes an apt configuration option, not a selector or a command.
cat > "$WORK/bin/apt-get" <<'STUB'
#!/bin/sh
# Preserve the simulation arguments before parsing consumes them.
[ "$1" != -s ] || echo "$*" > "$WORK/sim-args"
origin= suite= created= command=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o|--option|--format) shift ;;
		-o*|--option=*|--format=*) ;;
		indextargets|update|install) command="$1" ;;
		'Origin: '*) origin="${1#Origin: }" ;;
		'Suite: '*) suite="${1#Suite: }" ;;
		'Created-By: '*) created="${1#Created-By: }" ;;
	esac
	shift
done
case "$command" in
	indextargets)
		[ -z "$suite" ] || [ "$suite" = stable ] || exit 0
		[ -z "$created" ] || [ "$created" = Packages ] || exit 0
		for source in Glyndor Debian; do
			[ -z "$origin" ] || [ "$origin" = "$source" ] || continue
			dir="$WORK/lists"
			[ "$source" = Glyndor ] || dir="$WORK/foreign"
			for file in "$dir"/*; do [ ! -f "$file" ] || printf '%s\n' "$file"; done
		done ;;
	install)
		[ ! -f "$WORK/sim-fails" ] || { echo "E: Unable to lock the administration directory" >&2; exit 100; }
		cat "$WORK/plan.txt" 2>/dev/null
		;;
esac
exit 0
STUB
# apt-helper cat-file reads whichever form apt kept the index in.
cat > "$WORK/bin/apt-helper" <<'STUB'
#!/bin/sh
[ "$1" = cat-file ] || exit 2
printf '%s\n' "$2" >> "$WORK/read.log"
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
[ -f "$WORK/query-fails" ] && { echo "dpkg-query: error: cannot read the status file" >&2; exit 2; }
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
	rm -f "$WORK/seen.conf" "$WORK/read.log"
	env WORK="$WORK" PATH="$WORK/bin:$PATH" GNUPGHOME=/nonexistent \
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

# dpkg-query failing is not "nothing installed": the unit must fail, loudly,
# instead of reporting a green run that checked nothing.
printf 'ii  podup\n' > "$WORK/installed.txt"
: > "$WORK/query-fails"
run_upgrade > "$WORK/out.q"; rc=$?
check "when dpkg-query fails the script fails" "1" "$rc"
check "and says dpkg could not tell what is installed" "1" "$(grep -c 'could not tell which packages are installed' "$WORK/out.q")"
check "and does not claim there is nothing to upgrade" "0" "$(grep -c 'nothing to upgrade' "$WORK/out.q" || true)"
check "and the engine does not run" "0" "$(ran)"
rm -f "$WORK/query-fails"

printf 'ii  podup\nii  libfoo.bar+baz\nun  epistle\n' > "$WORK/installed.txt"
: > "$WORK/plan.txt"
run_upgrade >/dev/null; rc=$?
check "when everything is current the script succeeds" "0" "$rc"
check "and the engine does not run" "0" "$(ran)"
check "only installed Glyndor packages are asked about" "1" \
	"$(grep -c 'install podup libfoo.bar+baz$' "$WORK/sim-args")"

# A valid foreign index must remain unread even alongside a valid Glyndor one.
mkdir -p "$WORK/foreign"
printf 'Package: curl\nVersion: 1\n' > "$WORK/foreign/debian_Packages"
run_upgrade >/dev/null; rc=$?
check "a foreign index does not prevent a healthy run" "0" "$rc"
check "the Glyndor index was read" "1" \
	"$(grep -cF "$WORK/lists/apt.glyndor.net_dists_stable_main_binary-amd64_Packages" "$WORK/read.log")"
check "an index from another origin is never read" "0" \
	"$(grep -cF "$WORK/foreign/debian_Packages" "$WORK/read.log")"
rm -rf "$WORK/foreign"

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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
