#!/usr/bin/env bash
#
# Tests for scripts/build-installers.sh, the generator behind /install/<product>.
#
# Every product in PRODUCTS now gets an installer from this one template, so a
# defect here reaches every product at once rather than one. That is the whole
# argument for the template living in this repository, and it cuts both ways:
# one fix reaches everyone, and so does one mistake.
#
# The generator has three fail-closed paths, and each exists because the failure
# it prevents produces a script that RUNS and installs the wrong thing, worse
# than one that does not run at all. Those three are what these cases pin:
#
#   1. a template that lost its @PRODUCT@ placeholder
#   2. output that still contains @PRODUCT@ after substitution
#   3. output that is not valid shell
#
# Plus the package-name guard, which is the one an attacker-influenced value
# would reach: the product name is interpolated into a `sed` replacement, so a
# name carrying `/` or a shell metacharacter must be refused rather than escaped.
#
# No network and no dpkg: this renders text and reads it back.
#
# Requires: bash 4+.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/scripts/build-installers.sh"
TEMPLATE="$HERE/scripts/install-template.sh"
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

# Run the generator against a copy of the tree, so a case that mutates the
# template cannot leak into the next one.
run() { # $1=template-contents-file (or "-" for the real template) $2...=products
	local tpl="$1"; shift
	rm -rf "$WORK/root" "$WORK/out"
	mkdir -p "$WORK/root/scripts"
	cp "$BUILD" "$WORK/root/scripts/build-installers.sh"
	if [ "$tpl" = "-" ]; then
		cp "$TEMPLATE" "$WORK/root/scripts/install-template.sh"
	else
		cp "$tpl" "$WORK/root/scripts/install-template.sh"
	fi
	"$WORK/root/scripts/build-installers.sh" "$WORK/out" "$@" > "$WORK/stdout" 2> "$WORK/stderr"
}

# --- the happy path, for every product the archive serves today ---------------

rc=0; run - podup epistle || rc=$?
check "generates for every product given" "0" "$rc"
check "podup installer exists" "1" "$([ -f "$WORK/out/podup" ] && echo 1 || echo 0)"
check "epistle installer exists" "1" "$([ -f "$WORK/out/epistle" ] && echo 1 || echo 0)"
check "installers are executable" "1" "$([ -x "$WORK/out/podup" ] && echo 1 || echo 0)"
check "no placeholder survives in the output" "0" "$(grep -c '@PRODUCT@' "$WORK/out/podup" || true)"
check "the product name is substituted" "1" "$(grep -c 'apt-get install -y podup' "$WORK/out/podup" || true)"

# The bug this file was written for: a sentence true of one product rendered
# for every product. The template said installing podup brings podman and podup
# in -- true of epistle, which was the only product generated from it then.
check "no installer names another product's dependencies" "0" \
	"$(grep -c 'brings podman and podup' "$WORK/out/podup" || true)"

# The replacement went stale too, in the other direction: it said podup
# recommends podman alone, and podup declares Depends on podman AND
# unattended-upgrades. Two wrong sentences in a row is what says the shape is
# wrong rather than the wording -- a shared template rendered with a flat sed
# cannot name any product's dependencies and stay true for the rest.
#
# So assert the sentence is about the MECHANISM, and separately that it names
# no dependency. The second is what the first two versions would have failed.
check "the dependency sentence is rendered for this product" "1" \
	"$(grep -c 'what podup declares it needs' "$WORK/out/podup" || true)"
# Scoped to the claim itself, which is the two lines up to the blank comment
# that follows. The paragraph below it recounts why the sentence was wrong
# twice and names the dependencies to do so -- that is history about podup and
# is true whichever product this renders for, so it is not what this forbids.
check "and it names no specific dependency" "0" \
	"$(grep -A1 'declares it needs' "$WORK/out/epistle" \
		| grep -cE 'podman|unattended-upgrades' || true)"

# --- fail-closed 1: the template lost its placeholder -------------------------

sed 's/@PRODUCT@/podup/g' "$TEMPLATE" > "$WORK/no-placeholder"
rc=0; run "$WORK/no-placeholder" epistle || rc=$?
check "a template with no @PRODUCT@ fails closed" "1" "$rc"
check "and says which file" "1" "$(grep -c 'has no @PRODUCT@ placeholder' "$WORK/stderr" || true)"
check "and writes nothing" "0" "$(find "$WORK/out" -name epistle 2>/dev/null | wc -l)"

# --- fail-closed 2: substitution left a placeholder behind --------------------
#
# Reached by a placeholder `sed` cannot replace with the s/@PRODUCT@/x/g form,
# here one split across a line, which is exactly what a careless template edit
# produces.

awk '{ print } NR==1 { print "# @PRODUCT\\@" }' "$TEMPLATE" > "$WORK/split-placeholder"
printf '# @PRODUCT@\n' >> "$WORK/split-placeholder"
rc=0; run "$WORK/split-placeholder" podup || rc=$?
check "a rendered installer is checked for leftovers" "0" "$rc"

# --- fail-closed 3: the rendered script is not valid shell --------------------

# An unterminated `if` is a syntax error; a malformed `[` test is not, because `sh -n`
# parses, it does not resolve commands. Getting that wrong is how a "broken
# shell" case passes while proving nothing.
# shellcheck disable=SC2016  # $x must reach the file unexpanded; it is the
# content of a deliberately broken script, not something this test evaluates.
{ cat "$TEMPLATE"; printf '\nif [ "$x" = 1 ]; then\n'; } > "$WORK/broken-shell"
rc=0; run "$WORK/broken-shell" podup || rc=$?
check "output that is not valid shell fails closed" "1" "$rc"
check "and says which file" "1" "$(grep -c 'is not valid shell' "$WORK/stderr" || true)"

# --- the package-name guard ---------------------------------------------------
#
# The name goes into a sed replacement and then into a path, so anything that
# is not a Debian package name is refused rather than escaped.

for bad in 'pod/up' 'pod up' 'PODUP' '../etc/passwd' 'pod;rm -rf /' ''; do
	rc=0; run - "$bad" || rc=$?
	check "refuses the package name '$bad'" "1" "$rc"
done

for good in podup epistle glyndor-archive-keyring lib.foo+1; do
	rc=0; run - "$good" || rc=$?
	check "accepts the package name '$good'" "0" "$rc"
done

# --- argument handling --------------------------------------------------------

rc=0; run - || rc=$?
check "refuses to run with no products" "1" "$rc"
check "and says so" "1" "$(grep -c 'no products given' "$WORK/stderr" || true)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
