#!/usr/bin/env bash
#
# Fail when a product of the roster has no release the publish could use.
#
# Usage: roster-has-releases.sh
#
# The publish resolves the latest release of every product in PRODUCTS, then takes exactly
# one `*_<arch>.deb` and one `*_<arch>.deb.sig` for every architecture the entry declares,
# and stops when it cannot. One product that fails that stops the whole archive from
# refreshing: it happened on 15 November 2026 with epistle-panel, listed a day before its
# first release, and it was found by the next scheduled run. This asks the same questions
# before the merge, and with the same selection rule as publish.yml: a tag alone is not enough.
#
# Exit 0 every product has a usable release; 1 a product has none or one the publish would
# refuse (named on stdout and as an error annotation); 2 the answer could not be obtained
# (the API failed, the repository does not exist, the roster could not be read): never a
# pass, and never "has no release".
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root/.github/workflows/publish.yml"
org="${ROSTER_ORG:-Glyndor}"

line() { { grep -oE "^[[:space:]]*$1:[[:space:]]*\"[^\"]*\"" "$workflow" || true; } | head -1 | sed 's/.*"\(.*\)"/\1/'; }
archs_all="$(line ARCHITECTURES)"
specs="$(line PRODUCTS)"
if [ -z "$specs" ] || [ -z "$archs_all" ]; then
	echo "::error::no PRODUCTS or ARCHITECTURES list found in .github/workflows/publish.yml" >&2
	exit 2
fi

missing=0
unknown=0
for spec in $specs; do
	p="${spec%%:*}"
	if [ "$spec" = "$p" ]; then
		archs="$archs_all"
	else
		archs="$(tr ',' ' ' <<<"${spec#*:}")"
	fi
	if ! [[ "$p" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
		echo "::error::the roster names '$p', which is not a plain product name" >&2
		unknown=1
		continue
	fi
	err="$(mktemp)"
	if out="$(gh release view --repo "$org/$p" --json tagName,assets --jq '.tagName, (.assets[].name)' 2>"$err")" && [ -n "$out" ]; then
		tag="$(head -n 1 <<<"$out")"
		names="$(tail -n +2 <<<"$out")"
		ok=1
		for arch in $archs; do
			debs="$(grep -cE "_${arch}\\.deb\$" <<<"$names" || true)"
			sigs="$(grep -cE "_${arch}\\.deb\\.sig\$" <<<"$names" || true)"
			if [ "$debs" -ne 1 ] || [ "$sigs" -ne 1 ]; then
				echo "::error::$org/$p's $tag release carries $debs $arch .deb and $sigs .deb.sig file(s), and the publish needs exactly one of each; list a product in PRODUCTS only once its release has them" >&2
				echo "NONE  $p ($tag lacks a usable $arch package)"
				ok=0
				missing=1
			fi
		done
		[ "$ok" -eq 1 ] && echo "ok    $p: latest release $tag has a .deb and a .sig for: $archs"
	elif grep -qiE 'release not found|no releases found' "$err"; then
		# The same answer comes for a repository with no release and for one that does not
		# exist, and only the first is a missing release.
		if gh repo view "$org/$p" --json name --jq .name >/dev/null 2>&1; then
			echo "::error::$org/$p has no release, and the publish stops when it cannot resolve one; list a product in PRODUCTS only with its first release" >&2
			echo "NONE  $p (no release)"
			missing=1
		else
			echo "::error::$org/$p does not exist or cannot be read: a renamed or misspelt roster entry, not a missing release" >&2
			unknown=1
		fi
	else
		echo "::error::could not learn whether $org/$p has a release: $(head -c 200 "$err")" >&2
		unknown=1
	fi
	rm -f "$err"
done

[ "$unknown" -eq 0 ] || exit 2
[ "$missing" -eq 0 ] || exit 1
