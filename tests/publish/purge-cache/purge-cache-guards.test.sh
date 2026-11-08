#!/usr/bin/env bash
#
# Tests for the refusals in scripts/publish/purge-cache.sh that no other suite
# reaches, and for how it hands the Cloudflare token to curl.
#
# Every refusal here is fail-closed: the purge runs after the sync has already
# landed, so a script that shrugs at a half-built tree and purges a shorter list
# reports success over an edge that still serves the previous archive. Each case
# plants the one condition the guard names and requires that guard's own
# message, so a case that goes red for another reason does not count.
#
# The token case runs the real script against a curl on PATH that records its
# argv. Putting the token in an -H argument would leave it readable in
# /proc/<pid>/cmdline for the life of the request.
#
# Requires: bash, jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PURGE="$HERE/scripts/publish/purge-cache.sh"
WORK="$(mktemp -d)"
BUILT="$WORK/public"
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

# A curl that records what it was asked and answers the shape the script parses.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$ARGV_LOG"
printf '{"success":true,"errors":[]}'
STUB
chmod +x "$WORK/bin/curl"
export ARGV_LOG="$WORK/argv"
export PATH="$WORK/bin:$PATH"
export CF_TOKEN="secret-token-value" CF_ZONE="zone" CF_API_BASE="http://127.0.0.1:9/v4"

# A complete tree: one architecture, one product, the root files the purge
# requires and one installer. Each case below removes or bends one thing.
build() { # $1=extra index lines to declare in the Release
	rm -rf "$BUILT"
	mkdir -p "$BUILT/dists/stable/main/binary-amd64" "$BUILT/install"
	{
		echo "SHA256:"
		echo " deadbeef 1 main/binary-amd64/Packages"
		printf '%s' "$1"
	} > "$BUILT/dists/stable/Release"
	printf 'Package: p\nFilename: pool/main/p/p/p_1_amd64.deb\n\n' \
		> "$BUILT/dists/stable/main/binary-amd64/Packages"
	printf '#!/bin/sh\n' > "$BUILT/install/p"
	for f in index.html glyndor-archive-keyring.deb glyndor-archive-keyring.deb.asc; do
		printf 'x\n' > "$BUILT/$f"
	done
}

run() { # prints "<exit> <output>"
	local out rc=0
	out="$("$PURGE" https://apt.example "$BUILT" 2>&1)" || rc=$?
	echo "$rc $out"
}

refuses() { # <description> <expected message fragment>
	local got
	got="$(run)"
	check "$1: exits 1" "1" "${got%% *}"
	case "$got" in
		*"$2"*) check "$1: names its guard" "yes" "yes" ;;
		*) check "$1: names its guard" "contains $2" "$got" ;;
	esac
}

# --- the control: the complete tree is accepted -------------------------------
build ""
: > "$ARGV_LOG"
got="$(run)"
check "a complete tree is purged" "0" "${got%% *}"

# --- the token never reaches argv ---------------------------------------------
check "the token is absent from curl's argv" "0" \
	"$(grep -c 'secret-token-value' "$ARGV_LOG" || true)"
check "curl reads the credential from a header file" "yes" \
	"$(grep -q '^@' "$ARGV_LOG" && echo yes || echo no)"
check "the header file is the one passed to -H" "yes" \
	"$(grep -B1 '^@' "$ARGV_LOG" | head -1 | grep -qx -- '-H' && echo yes || echo no)"

# --- the per-attempt ceiling is validated like the budget ---------------------
for bad in abc 0; do
	rc=0
	out="$(PURGE_TRANSFER_MAX="$bad" "$PURGE" https://apt.example "$BUILT" 2>&1)" || rc=$?
	check "PURGE_TRANSFER_MAX=$bad exits 1" "1" "$rc"
done
rc=0
out="$(PURGE_TRANSFER_MAX=abc "$PURGE" https://apt.example "$BUILT" 2>&1)" || rc=$?
case "$out" in
	*"per-attempt ceiling must be a positive integer"*) check "a non-numeric ceiling is named" "yes" "yes" ;;
	*) check "a non-numeric ceiling is named" "the integer message" "$out" ;;
esac
rc=0
out="$(PURGE_TRANSFER_MAX=0 "$PURGE" https://apt.example "$BUILT" 2>&1)" || rc=$?
case "$out" in
	*"per-attempt ceiling must be at least 1 second"*) check "a zero ceiling is named" "yes" "yes" ;;
	*) check "a zero ceiling is named" "the at-least message" "$out" ;;
esac

# --- a built tree that is incomplete is refused, not purged short -------------
build ""
sed -i '/deadbeef/d' "$BUILT/dists/stable/Release"
refuses "a Release declaring no index files" "declares no index files to purge"

build ""
rm -f "$BUILT/dists/stable/main/binary-amd64/Packages"
refuses "a tree with no Packages index" "has no Packages index"

build ""
: > "$BUILT/dists/stable/main/binary-amd64/Packages"
refuses "indices that declare no packages" "declare no packages to purge"

build ""
rm -f "$BUILT/index.html" "$BUILT/glyndor-archive-keyring.deb" "$BUILT/glyndor-archive-keyring.deb.asc"
refuses "a tree with nothing at its root" "has no files at its root"

# --- the indices must fit one request ------------------------------------------
# Three fixed index URLs plus the declared paths: 28 declared makes 31 > 30.
extra=""
for i in $(seq 1 28); do
	extra="$extra deadbeef 1 main/binary-amd64/extra$i
"
done
build "$extra"
refuses "an index list that cannot fit one request" "index URLs exceed BATCH_SIZE"

echo "DONE $(basename "$0") $pass $fail"
[ "$fail" -eq 0 ]
