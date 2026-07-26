#!/usr/bin/env bash
#
# Purge the mutable, fixed-name files of a published archive from Cloudflare.
#
# Cloudflare caches by URL. A fresh sync changes the bytes behind the same URL,
# so without a purge apt can fetch a new InRelease and a stale Packages it no
# longer matches (hash/size mismatch). The immutable pool/ objects are purged
# too: their filename carries the version, but the keyring package is rebuilt
# under a stable name every run, and a bad edge copy of a pool object served
# `immutable, max-age=31536000` would outlive a bad index by a year.
#
# The URL list is DERIVED from the Release and Packages files the run just
# built, never written by hand. A hand-maintained list drifted from reprepro in
# both directions once already (#48): it named a Packages.xz reprepro does not
# emit, and never named the per-architecture Release files it does.
#
# Usage: purge-cache.sh <archive-url> <built-dir>
#   <archive-url>  public base URL, e.g. https://apt.glyndor.net
#   <built-dir>    the directory build-repo.sh wrote (contains dists/, pool/)
#
# Environment: CF_TOKEN (Cloudflare Bearer token), CF_ZONE (zone id),
# and optionally CF_API_BASE to point the request somewhere else (the tests
# use a local server; production leaves it at the default).
set -euo pipefail

ARCHIVE_URL="${1:-}"
BUILT_DIR="${2:-}"
CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

# Cloudflare rejects a purge-by-URL request carrying more than this many files.
# The list grows with every product and every architecture, so the request is
# split rather than refused: at the roster in the product context, two
# architectures fit in one request and three do not.
BATCH_SIZE=30

if [ -z "$ARCHIVE_URL" ] || [ -z "$BUILT_DIR" ]; then
	echo "usage: purge-cache.sh <archive-url> <built-dir>" >&2
	exit 2
fi

for v in CF_TOKEN CF_ZONE; do
	eval "[ -n \"\${$v:-}\" ]" \
		|| { echo "::error::$v is not configured."; exit 1; }
done

release="$BUILT_DIR/dists/stable/Release"
[ -r "$release" ] \
	|| { echo "::error::no signed Release at $release; nothing to derive a purge list from"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The index files the signed Release declares. Reading them out of the Release
# means an index file reprepro starts or stops emitting is followed
# automatically, and adding an architecture has one less place to remember.
index_paths="$(awk '
	/^SHA256:/          { in_section = 1; next }
	/^[^[:space:]]/     { in_section = 0 }
	in_section && NF == 3 { print $3 }
' "$release" | sort -u)"
[ -n "$index_paths" ] \
	|| { echo "::error::the built Release declares no index files to purge"; exit 1; }

# And the packages those indices point at.
pool_paths="$(awk '/^Filename:/ { print $2 }' \
	"$BUILT_DIR"/dists/stable/main/binary-*/Packages | sort -u)"
[ -n "$pool_paths" ] \
	|| { echo "::error::the built indices declare no packages to purge"; exit 1; }

{
	printf '%s\n' \
		"$ARCHIVE_URL/dists/stable/InRelease" \
		"$ARCHIVE_URL/dists/stable/Release" \
		"$ARCHIVE_URL/dists/stable/Release.gpg" \
		"$ARCHIVE_URL/glyndor-archive-keyring.deb" \
		"$ARCHIVE_URL/index.html"
	printf '%s\n' "$index_paths" | sed "s|^|$ARCHIVE_URL/dists/stable/|"
	printf '%s\n' "$pool_paths" | sed "s|^|$ARCHIVE_URL/|"
} | awk 'NF' | sort -u > "$work/urls"

total="$(wc -l < "$work/urls")"

# Pass the token via a header file, not argv: an -H argument is world-visible
# in /proc/<pid>/cmdline for the lifetime of the call.
hdr="$work/hdr"
printf 'Authorization: Bearer %s\n' "$CF_TOKEN" > "$hdr"

sent=0
batches=0
while [ "$sent" -lt "$total" ]; do
	# jq -R/-s builds the JSON array from the raw lines, so a URL can never
	# break out of the payload the way hand-assembled quoting could.
	body="$(sed -n "$((sent + 1)),$((sent + BATCH_SIZE))p" "$work/urls" \
		| jq -R . | jq -sc '{files: .}')"

	resp="$(curl -sS --retry 3 --retry-all-errors --retry-delay 5 -X POST \
		"$CF_API_BASE/zones/$CF_ZONE/purge_cache" \
		-H @"$hdr" \
		-H "Content-Type: application/json" \
		--data "$body")"

	# jq -e parses the actual JSON structure instead of grep matching the raw
	# response text, which a `"success":true` embedded in an unrelated field
	# (or a differently formatted but still successful response) could fool
	# either way.
	echo "$resp" | jq -e '.success == true' >/dev/null \
		|| { echo "::error::Cloudflare purge failed on batch $((batches + 1)): $resp"; exit 1; }

	sent=$((sent + BATCH_SIZE))
	batches=$((batches + 1))
done

# Print what was purged. The list is derived rather than written, so the run log
# is the only place it can be audited after the fact.
echo "Cloudflare cache purged, $total URL(s) in $batches request(s):"
sed 's/^/  /' "$work/urls"
