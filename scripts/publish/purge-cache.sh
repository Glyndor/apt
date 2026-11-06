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
# The URL list is DERIVED from the tree the run just built, never written by
# hand. A hand-maintained list drifted from reprepro in both directions once
# already (#48): it named a Packages.xz reprepro does not emit, and never named
# the per-architecture Release files it does. It then stayed behind twice more,
# on the bootstrap installers and on the keyring signature, each time because a
# new served file had to be remembered somewhere separate from where it is
# produced.
#
# Usage: purge-cache.sh <archive-url> <built-dir> [<budget-seconds>]
#   <archive-url>     public base URL, e.g. https://apt.glyndor.net
#   <built-dir>       the directory build-repo.sh wrote (contains dists/, pool/)
#   <budget-seconds>  the time the WHOLE purge may take (default 120)
#
# Environment: CF_TOKEN (Cloudflare Bearer token), CF_ZONE (zone id),
# and optionally CF_API_BASE to point the request somewhere else (the tests
# use a local server; production leaves it at the default).
#
# PRUNED_PATHS names a file with the archive-relative paths this publish
# removed from the bucket, one per line: the installers of the products that
# left the roster. They cannot come from the built tree the way every other
# path in the list does, because a removed installer is by definition not in
# it. They still have to be purged: the edge holds an installer for a day, so
# deleting the object from the bucket does not make the edge forget it.
set -euo pipefail

ARCHIVE_URL="${1:-}"
# One slash between the base and a path: "https://x//dists/..." is another URL to
# Cloudflare, so the purge would succeed and clear nothing that is served.
ARCHIVE_URL="${ARCHIVE_URL%/}"
BUILT_DIR="${2:-}"
CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

# The budget for the WHOLE purge, in seconds.
#
# It exists because curl's own retry multiplies the per-attempt deadline. One
# hung purge request was four attempts of --max-time 300 plus the delays
# between them: 1200s of transfer, against a publish job allowed 900s, and the
# operator read "cancelled after 15 minutes" instead of which group of URLs
# was not purged. The read-back that follows this step in the publish got a
# budget for exactly this reason on 2026-09-08; the purge, which runs first,
# did not have one.
#
# publish.yml passes it from beside the job's `timeout-minutes: 15` rather than
# letting it default here, so the two numbers are read together instead of
# drifting apart in two files.
BUDGET="${3:-120}"

# Cloudflare rejects a purge-by-URL request carrying more than this many files.
# The list grows with every product and every architecture, so the request is
# split rather than refused: at the roster in the product context, two
# architectures fit in one request and three do not.
BATCH_SIZE=30

# The ceiling for ONE attempt of one request. A purge carries at most 30 URLs
# of metadata, so this is generous against the clock and tight against the
# budget: it is what keeps a single hung request from eating the whole purge.
#
# Overridable so the suite can exercise the budget without waiting out a
# 30-second deadline. Production never sets it. It is validated below like
# the budget, so the expansion below is a number and nothing else.
TRANSFER_MAX="${PURGE_TRANSFER_MAX:-30}"
# The connect phase is short or the peer is not there at all.
CONNECT_MAX=20
# The wait between two attempts.
RETRY_DELAY=5

if [ -z "$ARCHIVE_URL" ] || [ -z "$BUILT_DIR" ]; then
	echo "usage: purge-cache.sh <archive-url> <built-dir> [<budget-seconds>]" >&2
	exit 2
fi

case "$BUDGET" in '' | *[!0-9]*)
	echo "::error::the purge budget must be a positive integer, got '$BUDGET'" >&2
	exit 1
	;;
esac
[ "$BUDGET" -ge 1 ] || { echo "::error::the purge budget must be at least 1 second" >&2; exit 1; }
case "$TRANSFER_MAX" in '' | *[!0-9]*)
	echo "::error::the per-attempt ceiling must be a positive integer, got '$TRANSFER_MAX'" >&2
	exit 1
	;;
esac
[ "$TRANSFER_MAX" -ge 1 ] || { echo "::error::the per-attempt ceiling must be at least 1 second" >&2; exit 1; }

# Seconds since the purge started. The budget covers the whole script, not
# only the requests, so the time spent deriving the purge list counts too.
STARTED_AT="$(date -u +%s)"
elapsed() { echo $(( $(date -u +%s) - STARTED_AT )); }
# What is left of the budget. Read before every request rather than once at
# the start: a purge that spends its budget on the first batch must not start
# the second one with the deadline it would have had at the beginning.
remaining() { echo $(( BUDGET - $(elapsed) )); }

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
' "$release" | LC_ALL=C sort -u)"
[ -n "$index_paths" ] \
	|| { echo "::error::the built Release declares no index files to purge"; exit 1; }
# The Release is signed by us, but a path that climbs out of dists/ would still
# be purged as a URL elsewhere on the host.
case "$index_paths" in
	*..*) echo "::error::the built Release names an index path containing '..'"; exit 1 ;;
esac

# And the packages those indices point at.
compgen -G "$BUILT_DIR/dists/stable/main/binary-*/Packages" >/dev/null \
	|| { echo "::error::the built tree has no Packages index; there is nothing to purge"; exit 1; }
pool_paths="$(awk '/^Filename:/ { print $2 }' \
	"$BUILT_DIR"/dists/stable/main/binary-*/Packages | LC_ALL=C sort -u)"
[ -n "$pool_paths" ] \
	|| { echo "::error::the built indices declare no packages to purge"; exit 1; }

# The bootstrap installers. Derived from what was built rather than from
# PRODUCTS, for the same reason the index list is derived from the Release: a
# hand-kept list drifts from what is actually served.
#
# These were missing, and the omission is the expensive kind. They are the
# fixed-name mutable files this step exists for -- Cloudflare serves them with
# `max-age=86400`, so a stale one persists for a day -- and their content is the
# script a stranger pipes into a root shell. Measured on 2026-08-27: a fix to
# install-template.sh landed in R2 and the edge kept serving the previous script
# to `install/podup` while `install/epistle`, less trafficked and so uncached,
# served the new one. Every step of the publish reported success.
[ -d "$BUILT_DIR/install" ] \
	|| { echo "::error::the built tree has no install/ directory; every product's install line would stay stale"; exit 1; }
installer_paths="$(find "$BUILT_DIR/install" -maxdepth 1 -type f -printf 'install/%f\n' \
	2>/dev/null | LC_ALL=C sort -u)"
[ -n "$installer_paths" ] \
	|| { echo "::error::no bootstrap installer was built; there is nothing to purge and every product's install line is stale"; exit 1; }

# The paths this publish removed from the bucket. Every list above is derived
# from what was built, and a removed installer is not among them: that is the
# whole reason it had to be removed. The publish hands them over in a file,
# because by the time the edge is purged the objects are gone and there is
# nothing left to list.
pruned_paths=""
if [ -n "${PRUNED_PATHS:-}" ]; then
	if [ ! -f "$PRUNED_PATHS" ] || [ ! -r "$PRUNED_PATHS" ]; then
		echo "::error::the list of removed paths at $PRUNED_PATHS is missing; the edge purge cannot cover what this publish removed"
		exit 1
	fi
	pruned_paths="$(cat "$PRUNED_PATHS")"
	# A path that climbs out of the archive would be purged as a URL
	# elsewhere on the host, and one that is not under install/ is not
	# something this step knows how to have removed.
	case "$pruned_paths" in
		*..*) echo "::error::the list of removed paths names a path containing '..'"; exit 1 ;;
	esac
	while IFS= read -r _removed; do
		[ -n "$_removed" ] || continue
		case "$_removed" in
			install/*) ;;
			*) echo "::error::the list of removed paths names '$_removed', which is not under install/"; exit 1 ;;
		esac
	done <<< "$pruned_paths"
fi

# And the files the publish writes to the root of the archive. Derived for the
# same reason the three lists above are. This one was named by hand, and it
# stopped matching what is served the moment the publish started putting a
# detached signature beside the keyring package: `index.html` and the keyring
# were listed, the signature was not, and nothing said so.
#
# `public/` at depth one holds exactly what the run put there, since dists/,
# pool/ and install/ are directories.
root_paths="$(find "$BUILT_DIR" -maxdepth 1 -type f -printf '%f\n' \
	2>/dev/null | LC_ALL=C sort -u)"
[ -n "$root_paths" ] \
	|| { echo "::error::the built tree has no files at its root; the keyring package and the landing page are served from there"; exit 1; }

# These two are named rather than left to the count above, because they are the
# pair the bootstrap installer fetches together: it verifies the detached
# signature over the package before installing it, so an edge that still serves
# one of them from a previous run is a refused install on a machine nobody is
# attacking. A run that did not produce both is broken upstream of this step and
# must not go on to purge a shorter list.
for _required in glyndor-archive-keyring.deb glyndor-archive-keyring.deb.asc; do
	printf '%s\n' "$root_paths" | grep -qxF "$_required" \
		|| { echo "::error::$_required is missing from $BUILT_DIR; the keyring package and its signature are served together and have to be purged together"; exit 1; }
done

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
# failing before the indices leaves old indices pointing at old files, and the
# archive simply stays on the previous version, consistent. Purging indices
# first and failing leaves a new InRelease over stale Packages, which breaks.
#
# The indices go in a single request so they move together: there are nine of
# them against a BATCH_SIZE of 30, and the guard below refuses to run rather
# than split them if that ever stops being true.
{
	printf '%s\n' "$root_paths" | sed "s|^|$ARCHIVE_URL/|"
	printf '%s\n' "$pool_paths" | sed "s|^|$ARCHIVE_URL/|"
	printf '%s\n' "$installer_paths" | sed "s|^|$ARCHIVE_URL/|"
	# The empty list is dropped before the base URL is prefixed: an empty
	# path prefixed with it would be the archive root, which is not one of
	# the URLs this step purges.
	printf '%s\n' "$pruned_paths" | awk 'NF' \
		| jq -Rr 'split("/") | map(@uri) | join("/")' | sed "s|^|$ARCHIVE_URL/|"
} | awk 'NF' | LC_ALL=C sort -u > "$work/urls-content"

{
	printf '%s\n' \
		"$ARCHIVE_URL/dists/stable/InRelease" \
		"$ARCHIVE_URL/dists/stable/Release" \
		"$ARCHIVE_URL/dists/stable/Release.gpg"
	printf '%s\n' "$index_paths" | sed "s|^|$ARCHIVE_URL/dists/stable/|"
} | awk 'NF' | LC_ALL=C sort -u > "$work/urls-index"

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

# What a failed purge leaves behind, said the same way whichever group failed.
#
# Either way the indices were not purged while the pool was: the sync has
# already dropped the superseded packages from R2, so an edge still serving
# the previous index names packages that are no longer there. A client on that
# edge sees a missing package until the next successful purge or cache
# expiry. The operator reading a red run needs to know which of those it is,
# because they call for very different responses.
warn_indices_not_purged() {
	echo "::warning::the indices were not purged; edges may keep serving the previous index while the pool already lost its superseded packages, so a client on a stale edge can see a missing package until the next successful purge or cache expiry"
}

# And the installers this publish removed. Their objects are already gone from
# the bucket, so the edge is the only copy left of the script of a product
# that no longer exists, and it holds it for a day.
warn_pruned_not_purged() {
	[ -n "$pruned_paths" ] || return 0
	echo "::warning::the installers this publish removed were not purged; edges may keep serving the installer of a product that left the roster until the next successful purge or cache expiry"
}

# The diagnosis the job's timeout would otherwise never let the script print.
# It runs while there is still time, it names the group and the batch that
# were in flight, and it says that the budget is what stopped it.
budget_stop() { # $1=group label $2=batch number $3=before|on $4=curl exit (optional)
	if [ "$3" = "before" ]; then
		echo "::error::the ${BUDGET}s purge budget ran out before the $1 batch $2 request; the Cloudflare purge did not finish, so the edge may keep serving the previous index"
	else
		echo "::error::the ${BUDGET}s purge budget ran out on the $1 batch $2 request: curl exited with $4, and the Cloudflare purge did not finish, so the edge may keep serving the previous index"
	fi
	warn_indices_not_purged
	warn_pruned_not_purged
	exit 1
}

# Purge one file's worth of URLs in BATCH_SIZE-sized requests. $2 names the
# group for the error message, so a failure says which half stopped.
purge_file() { # $1=path $2=label
	_count="$(wc -l < "$1")"
	_sent=0
	while [ "$_sent" -lt "$_count" ]; do
		_batch=$((batches + 1))

		_left="$(remaining)"
		if [ "$_left" -le 0 ]; then
			budget_stop "$2" "$_batch" "before"
		fi

		# jq -R/-s builds the JSON array from the raw lines, so a URL can never
		# break out of the payload the way hand-assembled quoting could.
		body="$(sed -n "$((_sent + 1)),$((_sent + BATCH_SIZE))p" "$1" \
			| jq -R . | jq -sc '{files: .}')"

		# Bound this curl: without a deadline a hung purge would leave a fresh
		# archive behind a stale edge cache with the job wedged rather than
		# failed, because the step runs after the sync has already landed:
		# every step of the publish reports success, the new Packages pairs
		# with the previous InRelease the cache keeps serving, and CI does not
		# turn red.
		#
		# Every deadline below is the time that is LEFT, not a fixed number:
		# --max-time bounds one attempt, --retry-max-time bounds the whole
		# retry sequence, and the delay between two attempts cannot outlast
		# the budget either. A fixed --max-time 300 with curl's own retries
		# is four attempts of five minutes each, which is how this step used
		# to cost more than the job it runs in.
		#
		# The deadlines are expanded unquoted because each of them is an
		# integer this script computed or validated above. --max-time is
		# the one that has to be: the repository's own "every curl carries
		# --max-time" gate reads a deadline as that flag followed by a
		# number or a variable, and a quoted expansion is not a shape it
		# recognises.
		_max=$(( _left < TRANSFER_MAX ? _left : TRANSFER_MAX ))
		_connect=$(( _left < CONNECT_MAX ? _left : CONNECT_MAX ))
		_delay=$(( _left < RETRY_DELAY ? _left : RETRY_DELAY ))

		_rc=0
		resp="$(curl -sS --retry 3 --retry-all-errors --retry-delay "$_delay" \
			--retry-max-time "$_left" -X POST \
			--connect-timeout "$_connect" --max-time $_max \
			"$CF_API_BASE/zones/$CF_ZONE/purge_cache" \
			-H @"$hdr" \
			-H "Content-Type: application/json" \
			--data "$body" 2> "$work/curl.err")" || _rc=$?

		if [ "$_rc" -ne 0 ]; then
			# The budget is measured again here rather than assumed: the
			# request can fail for its own reasons with time to spare, and
			# the two need different words.
			if [ "$(remaining)" -le 0 ]; then
				budget_stop "$2" "$_batch" "on" "$_rc"
			fi
			echo "::error::Cloudflare purge failed on $2 batch $_batch: curl exited with $_rc: $(cat "$work/curl.err")"
			warn_indices_not_purged
			warn_pruned_not_purged
			exit 1
		fi

		# jq -e parses the actual JSON structure instead of grep matching the raw
		# response text, which a `"success":true` embedded in an unrelated field
		# (or a differently formatted but still successful response) could fool
		# either way.
		echo "$resp" | jq -e '.success == true' >/dev/null || {
			echo "::error::Cloudflare purge failed on $2 batch $_batch: $resp"
			warn_indices_not_purged
			warn_pruned_not_purged
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
echo "Cloudflare cache purged, $total URL(s) in $batches request(s), $(elapsed)s of the ${BUDGET}s budget:"
sed 's/^/  /' "$work/urls"
