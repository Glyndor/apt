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

# Split into content and indices, and purge the indices LAST.
#
# A partial purge is not degradation for apt, it is a signature that does not
# verify: an InRelease naming hashes for a Packages the edge still serves from
# cache is a hard error on the updating machine, and it persists until the next
# publish. Batches can fail independently, so the order decides what a failure
# leaves behind.
#
# The asymmetry is what makes this safe. Pool files carry their version in the
# name (podup_3.8.0_amd64.deb), so purging the new one never touches the old;
# indices are fixed URLs whose contents change. Purging content first and
# failing before the indices leaves old indices pointing at old files — the
# archive simply stays on the previous version, consistent. Purging indices
# first and failing leaves a new InRelease over stale Packages, which breaks.
#
# The indices go in a single request so they move together: there are nine of
# them against a BATCH_SIZE of 30, and the guard below refuses to run rather
# than split them if that ever stops being true.
{
	printf '%s\n' \
		"$ARCHIVE_URL/glyndor-archive-keyring.deb" \
		"$ARCHIVE_URL/index.html"
	printf '%s\n' "$pool_paths" | sed "s|^|$ARCHIVE_URL/|"
} | awk 'NF' | sort -u > "$work/urls-content"

{
	printf '%s\n' \
		"$ARCHIVE_URL/dists/stable/InRelease" \
		"$ARCHIVE_URL/dists/stable/Release" \
		"$ARCHIVE_URL/dists/stable/Release.gpg"
	printf '%s\n' "$index_paths" | sed "s|^|$ARCHIVE_URL/dists/stable/|"
} | awk 'NF' | sort -u > "$work/urls-index"

index_total="$(wc -l < "$work/urls-index")"
[ "$index_total" -le "$BATCH_SIZE" ] || {
	echo "::error::$index_total index URLs exceed BATCH_SIZE=$BATCH_SIZE; they must purge in one request or a partial failure leaves apt with a signature that does not verify"
	exit 1
}

cat "$work/urls-content" "$work/urls-index" > "$work/urls"
total="$(wc -l < "$work/urls")"

# Pass the token via a header file, not argv: an -H argument is world-visible
# in /proc/<pid>/cmdline for the lifetime of the call.
hdr="$work/hdr"
printf 'Authorization: Bearer %s\n' "$CF_TOKEN" > "$hdr"

batches=0

# Purge one file's worth of URLs in BATCH_SIZE-sized requests. $2 names the
# group for the error message, so a failure says which half stopped.
purge_file() { # $1=path $2=label
	_count="$(wc -l < "$1")"
	_sent=0
	while [ "$_sent" -lt "$_count" ]; do
		# jq -R/-s builds the JSON array from the raw lines, so a URL can never
		# break out of the payload the way hand-assembled quoting could.
		body="$(sed -n "$((_sent + 1)),$((_sent + BATCH_SIZE))p" "$1" \
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
		echo "$resp" | jq -e '.success == true' >/dev/null || {
			echo "::error::Cloudflare purge failed on $2 batch $((batches + 1)): $resp"
			if [ "$2" = "content" ]; then
				echo "::notice::the indices were not purged, so the archive keeps serving the previous version consistently"
			fi
			exit 1
		}

		_sent=$((_sent + BATCH_SIZE))
		batches=$((batches + 1))
	done
}

# Content first: a failure here leaves the old indices in place, pointing at
# files that are still there. Indices last and in one request, so they never
# move halfway.
purge_file "$work/urls-content" "content"
purge_file "$work/urls-index" "index"

# Print what was purged. The list is derived rather than written, so the run log
# is the only place it can be audited after the fact.
echo "Cloudflare cache purged, $total URL(s) in $batches request(s):"
sed 's/^/  /' "$work/urls"
