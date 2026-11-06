#!/usr/bin/env bash
# Compare each served installer with its locally generated reference, byte for
# byte. A shebang (or valid shell syntax) says nothing about completeness.
# Usage: verify-installers.sh <base-url> <expected-dir> <product> [<product> ...]
set -euo pipefail
BASE_URL="${1:?missing base URL}"
EXPECTED="${2:?missing generated installer directory}"
shift 2
[ "$#" -gt 0 ] || { echo '::error::no installers to verify' >&2; exit 1; }
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
for product in "$@"; do
	case "$product" in
		*[!a-z0-9.+-]* | '' | [!a-z0-9]* | ?)
			echo "::error::invalid installer product: $product" >&2; exit 1 ;;
	esac
	[ -s "$EXPECTED/$product" ] || {
		echo "::error::missing generated installer for $product in $EXPECTED" >&2; exit 1;
	}
	url="${BASE_URL%/}/install/$product"
	if ! curl -fsS --connect-timeout 10 --max-time 30 "$url" -o "$body"; then
		echo "::error::installer transfer failed at $url" >&2
		exit 1
	fi
	if ! cmp -s "$EXPECTED/$product" "$body"; then
		echo "::error::installer content differs at $url from the generated installer" >&2
		exit 1
	fi
	echo "installer matches generated content for $product"
done
