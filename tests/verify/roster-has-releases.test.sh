#!/usr/bin/env bash
#
# Tests for scripts/verify/roster-has-releases.sh. A fake `gh` answers per product, so no
# case touches the network: a product with a release, one with none (the shape of the
# 15 November 2026 failure), one whose lookup fails, an empty roster and a hostile name.
# The three outcomes have to stay distinct: 0 every product has a release, 1 a product has
# none, 2 the answer could not be obtained.
#
# Requires: bash.
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

mkdir -p "$WORK/bin" "$WORK/repo/.github/workflows" "$WORK/repo/scripts/verify"
cp "$HERE/scripts/verify/roster-has-releases.sh" "$WORK/repo/scripts/verify/"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
# gh release view --repo ORG/NAME --json tagName --jq .tagName
repo=""
while [ "$#" -gt 0 ]; do
	[ "$1" = "--repo" ] && repo="$2"
	shift
done
case "$repo" in
	*/has-release) echo "v1.0.0" ;;
	*/no-release) echo "release not found" >&2; exit 1 ;;
	*/api-down) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
	*) echo "HTTP 404: Not Found" >&2; exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"

run() { # $1 = the PRODUCTS value, or - to leave the line out
	if [ "$1" = "-" ]; then
		printf 'env:\n  OTHER: "x"\n' > "$WORK/repo/.github/workflows/publish.yml"
	else
		printf 'env:\n  PRODUCTS: "%s"\n' "$1" > "$WORK/repo/.github/workflows/publish.yml"
	fi
	PATH="$WORK/bin:$PATH" bash "$WORK/repo/scripts/verify/roster-has-releases.sh" >"$WORK/out" 2>"$WORK/err"
	echo $?
}

check "a roster whose products all have a release passes" "0" "$(run 'has-release')"
check "an architecture spec is not part of the repository name" "0" "$(run 'has-release:all')"
check "a product with no release fails" "1" "$(run 'has-release no-release')"
check "and the product is named on stdout" "1" "$(grep -c '^NONE  no-release' "$WORK/out")"
check "and the error says the publish stops without one" "1" "$(grep -c 'the publish stops when it cannot resolve one' "$WORK/err")"
check "a product that exists but answers 404 is also a missing release" "1" "$(run 'has-release nonexistent')"
check "a failing lookup is neither a pass nor a missing release" "2" "$(run 'has-release api-down')"
check "and says the answer could not be learned" "1" "$(grep -c 'could not learn whether' "$WORK/err")"
check "a missing release and a failing lookup together report the failure" "2" "$(run 'no-release api-down')"
check "a roster that cannot be read fails with 2" "2" "$(run '-')"
check "a name that is not a plain product name is refused with 2" "2" "$(run 'has-release;touch-x')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
