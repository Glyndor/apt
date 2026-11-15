#!/usr/bin/env bash
#
# Fail when a product of the roster has no release the publish could download.
#
# Usage: roster-has-releases.sh
#
# The publish resolves the latest release of every product in PRODUCTS and stops when it
# cannot, so one product with no release stops the whole archive from refreshing: that is
# what happened on 15 November 2026 with epistle-panel, listed a day before its first
# release, and it was only found by the next scheduled run. Run on a pull request that
# touches the roster, this says so before the merge.
#
# Exit 0 every product has a release; 1 at least one has none (named on stdout and as an
# error annotation); 2 the answer could not be obtained for a product (the API failed,
# or the roster could not be read), which is never read as "has a release" and never as
# "has none" either.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root/.github/workflows/publish.yml"
org="${ROSTER_ORG:-Glyndor}"

roster="$({ grep -oE '^[[:space:]]*PRODUCTS:[[:space:]]*"[^"]*"' "$workflow" || true; } | head -1 | sed 's/.*"\(.*\)"/\1/' | tr ' ' '\n' | sed 's/:.*//' | { grep -v '^$' || true; })"
if [ -z "$roster" ]; then
	echo "::error::no PRODUCTS list found in .github/workflows/publish.yml" >&2
	exit 2
fi

missing=0
unknown=0
while IFS= read -r product; do
	if ! [[ "$product" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
		echo "::error::the roster names '$product', which is not a plain product name" >&2
		unknown=1
		continue
	fi
	err="$(mktemp)"
	if tag="$(gh release view --repo "$org/$product" --json tagName --jq .tagName 2>"$err")" && [ -n "$tag" ]; then
		echo "ok    $product: latest release $tag"
	elif grep -qiE 'release not found|HTTP 404|no releases found' "$err"; then
		echo "::error::$org/$product has no release, and the publish stops when it cannot resolve one; list a product in PRODUCTS only with its first release" >&2
		echo "NONE  $product"
		missing=1
	else
		echo "::error::could not learn whether $org/$product has a release: $(head -c 200 "$err")" >&2
		unknown=1
	fi
	rm -f "$err"
done <<<"$roster"

[ "$unknown" -eq 0 ] || exit 2
[ "$missing" -eq 0 ] || exit 1
