#!/usr/bin/env bash
#
# Download the .deb a product shipped in the release before the one this archive serves, so
# that an upgrade from it to the served package can be tried.
#
# Usage: previous-release.sh <product> <directory> [served version]
#
# The archive keeps the latest version of each product and no other: the publish deletes a
# superseded .deb from the pool as soon as the new index lands (docs/threat-model.md), so the
# version a machine had installed yesterday cannot be fetched from it. The product's own
# releases still carry it, so it is taken from there: the newest published release whose
# version is strictly lower than the served one, by the order dpkg uses. The served version is
# read from the live index unless it is given.
#
# The download is held to the digest GitHub reports for the asset and to the Package and
# Version the file itself declares; a file that disagrees is not installed. The downloaded
# package is not verified against the release signature: it is used as the starting point of a
# throwaway container, and what is under test is the archive's package, which is verified.
#
# Prints the path of the downloaded .deb on stdout and everything else on stderr.
# Exit 0 when a package was fetched, 3 when the product has no release below the served
# version (an upgrade cannot be tried, and that is not a pass), 1 for anything else.
# Environment: GH_TOKEN (gh), BASE_URL, ORG (default Glyndor), ARCH (default amd64).
set -euo pipefail

usage="usage: previous-release.sh <product> <directory> [served version]"
product="${1:?$usage}"
dir="${2:?$usage}"
served="${3:-}"
base_url="${BASE_URL:-https://apt.glyndor.net}"
org="${ORG:-Glyndor}"
arch="${ARCH:-amd64}"

fail() {
	echo "::error::previous-release: $*" >&2
	exit 1
}

[[ "$product" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "'$product' is not a plain product name"
[[ "$org" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || fail "'$org' is not a plain organisation name"
[[ "$arch" =~ ^[a-z0-9]+$ ]] || fail "'$arch' is not an architecture"
mkdir -p "$dir" || fail "cannot create $dir"

if [ -z "$served" ]; then
	index="$(curl -fsS --max-time 60 "$base_url/dists/stable/main/binary-$arch/Packages")" \
		|| fail "could not read the index of $base_url, so the served version is not known"
	served="$(awk -v p="$product" '$1 == "Package:" { cur = $2 } $1 == "Version:" && cur == p { print $2; exit }' <<<"$index")"
fi
[ -n "$served" ] || fail "$product is not in the index, so there is no served version to go back from"

releases="$(timeout 120 gh api "repos/$org/$product/releases?per_page=30")" \
	|| fail "could not list the releases of $org/$product"
rows="$(jq -r --arg p "$product" --arg a "$arch" '
	if type != "array" then error("not a list") else . end
	| .[] | select(.draft == false and .prerelease == false) | .tag_name as $tag
	| .assets[] | select(.name | test("^" + $p + "_[^/]+_" + $a + "\\.deb$"))
	| [$tag, .name, (.digest // "")] | @tsv' <<<"$releases")" \
	|| fail "the releases of $org/$product could not be read"

best_tag=""; best_name=""; best_digest=""; best_version=""
while IFS=$'\t' read -r tag name digest; do
	[ -n "$name" ] || continue
	version="${name#"${product}_"}"
	version="${version%"_${arch}.deb"}"
	dpkg --compare-versions "$version" lt "$served" || continue
	if [ -z "$best_version" ] || dpkg --compare-versions "$version" gt "$best_version"; then
		best_tag="$tag"; best_name="$name"; best_digest="$digest"; best_version="$version"
	fi
done <<<"$rows"

if [ -z "$best_version" ]; then
	echo "previous-release: $org/$product has no published release below $served, so an upgrade to it cannot be tried" >&2
	exit 3
fi
case "$best_digest" in
	sha256:????????????????????????????????????????????????????????????????) ;;
	*) fail "the release $best_tag of $org/$product reports no sha256 digest for $best_name, so the download cannot be checked" ;;
esac

timeout 600 gh release download "$best_tag" --repo "$org/$product" --pattern "$best_name" --dir "$dir" --clobber >&2 \
	|| fail "could not download $best_name from $org/$product $best_tag"
file="$dir/$best_name"
[ -f "$file" ] || fail "the download of $best_name left no file"
got="$(sha256sum "$file" | cut -d' ' -f1)"
[ "sha256:$got" = "$best_digest" ] || fail "$best_name is sha256:$got, not the $best_digest the release reports"
[ "$(dpkg-deb -f "$file" Package)" = "$product" ] || fail "$best_name does not declare the package $product"
[ "$(dpkg-deb -f "$file" Version)" = "$best_version" ] || fail "$best_name declares version $(dpkg-deb -f "$file" Version), not $best_version"

echo "previous-release: $product $best_version from $org/$product $best_tag, below the served $served" >&2
printf '%s\n' "$file"
