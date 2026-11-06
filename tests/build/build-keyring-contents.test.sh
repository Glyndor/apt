#!/usr/bin/env bash
#
# What the keyring package puts on a client, and with which permissions. A
# review changed the installed key to mode 0666, pointed Signed-By at another
# path and switched the source to http, and every other suite stayed green:
# they check that the files EXIST and that the version moves, not what is in
# them or who may write to them.
#
# The package is built from a throwaway git repository, as in
# tests/build/build-keyring.test.sh, so the suite is hermetic and works on a
# shallow clone.
#
# Requires: gpg, dpkg-deb, git.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# build <name> [mutate-script]: build the package from a copy of this checkout,
# after running the optional command in the copy's keyring/ directory.
build() {
	local repo="$WORK/$1/repo"; mkdir -p "$repo/scripts/build" "$repo/keyring" "$WORK/$1/out"
	cp "$HERE/scripts/build/build-keyring.sh" "$repo/scripts/build/"
	cp -r "$HERE"/keyring/* "$repo/keyring/"
	( cd "$repo/keyring" && eval "${2:-:}" )
	git -C "$repo" init -q; git -C "$repo" add -A
	git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
	"$repo/scripts/build/build-keyring.sh" "$WORK/$1/out" >/dev/null 2>&1 || true
	echo "$WORK/$1/out/glyndor-archive-keyring.deb"
}

# modes <deb>: "<mode> <owner> <path>" for every file, from the package itself.
modes() { dpkg-deb --contents "$1" | awk '{print $1, $2, $6}'; }
mode_of() { modes "$1" | awk -v p="$2" '$3 == p {print $1, $2}'; }

DEB="$(build real)"
check "control: the package was built" "yes" "$([ -s "$DEB" ] && echo yes || echo no)"

check "the installed key is readable by all and writable by root only" \
	"-rw-r--r-- root/root" "$(mode_of "$DEB" ./usr/share/keyrings/glyndor.gpg)"
check "the apt source is readable by all and writable by root only" \
	"-rw-r--r-- root/root" "$(mode_of "$DEB" ./etc/apt/sources.list.d/glyndor.sources)"
check "the upgrade script is executable and writable by root only" \
	"-rwxr-xr-x root/root" "$(mode_of "$DEB" ./usr/lib/glyndor-archive-keyring/glyndor-upgrade)"
check "no regular file in the package is writable by group or others" "0" \
	"$(modes "$DEB" | awk '$1 ~ /^-/ && substr($1,6,1) == "w" || $1 ~ /^-/ && substr($1,9,1) == "w"' | wc -l)"
check "no directory in the package is writable by group or others" "0" \
	"$(modes "$DEB" | awk '$1 ~ /^d/ && (substr($1,6,1) == "w" || substr($1,9,1) == "w")' | wc -l)"
check "every file in the package belongs to root" "0" \
	"$(modes "$DEB" | awk '$2 != "root/root"' | wc -l)"

# The package must not depend on the builder's umask. With 0002 the parent
# directories that `install -d` creates on the way used to ship group-writable,
# and the bytes differed from a build under 0022.
DEB2="$( umask 0002; build umask-0002 )"
DEB3="$( umask 0077; build umask-0077 )"
check "a build under umask 0002 ships no group-writable directory" "0" \
	"$(modes "$DEB2" | awk '$1 ~ /^d/ && substr($1,6,1) == "w"' | wc -l)"
check "a build under umask 0077 ships the same modes as one under 0002" \
	"$(modes "$DEB2")" "$(modes "$DEB3")"

# The source file as installed: https, the one archive, and a Signed-By that is
# exactly the path the package installs the key to.
SRC="$WORK/src"; mkdir -p "$SRC"; dpkg-deb --fsys-tarfile "$DEB" | tar -x -C "$SRC" ./etc/apt/sources.list.d/glyndor.sources
field() { sed -n "s/^$1: *//p" "$SRC/etc/apt/sources.list.d/glyndor.sources"; }
check "the source is fetched over https" "https://apt.glyndor.net" "$(field URIs)"
check "the source is the stable suite of the main component" "stable main" "$(field Suites) $(field Components)"
check "Signed-By is the path the package installs the key to" "/usr/share/keyrings/glyndor.gpg" "$(field Signed-By)"

# --- the checks above can be seen to fail ---------------------------------------
# A package built from a source file that points elsewhere must not satisfy them.
BAD="$(build http "sed -i 's|^URIs: https|URIs: http|' glyndor.sources")"
SRC2="$WORK/src2"; mkdir -p "$SRC2"; dpkg-deb --fsys-tarfile "$BAD" | tar -x -C "$SRC2" ./etc/apt/sources.list.d/glyndor.sources
check "control: a source switched to http is not https" "http://apt.glyndor.net" \
	"$(sed -n 's/^URIs: *//p' "$SRC2/etc/apt/sources.list.d/glyndor.sources")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
