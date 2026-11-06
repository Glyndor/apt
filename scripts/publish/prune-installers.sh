#!/usr/bin/env bash
#
# Remove the bootstrap installers the bucket still serves for the products
# that left the roster.
#
# The bucket is the archive; the roster is PRODUCTS. When a product leaves the
# roster its package leaves pool/ -- the sync deletes it there -- but its
# installer used to stay at /install/<product> for good. Nothing uploaded a
# deletion for it, nothing at the edge purged it, and nothing in this
# repository asked for it, because every check here asks for the products the
# roster HAS. The URL is the one the README and the landing page publish, so
# the script kept being served, for a product that no longer exists, carrying
# whatever faults a later fix to install-template.sh had already closed.
#
# The objects are removed by name, not by a sync pass, and the reason is the
# race this repository already paid for. A sync with --delete over install/
# would upload and delete in the same pass, and that is the shape that raced
# on run 29718989917: the comparator classified a key that is a strict prefix
# of a sibling (Packages of Packages.gz, Release of Release.gpg) as
# local-only and remote-only at once, so the run uploaded it and deleted it
# in the same breath. install/ is full of prefix pairs waiting to happen --
# epistle and epistle-panel -- and there the shorter name would be deleted by
# the pass that was meant to keep it. So the objects to remove are named
# first, out of the bucket's own listing, and deleted one call each. The
# bucket is read back afterwards to prove the served set is the built set.
#
# The listing is also the only inventory there is: no index declares an
# installer, so nothing in the archive says which ones exist.
#
# Usage: prune-installers.sh <built-install-dir> <bucket> <endpoint> [<removed-list>]
#   <built-install-dir>  the directory the installers were generated into
#   <bucket>             the bucket name, without the s3:// scheme
#   <endpoint>           the S3 endpoint to talk to
#   [<removed-list>]     a file to write the removed paths into, one per line,
#                        for the edge purge to cover
#
# Requires: aws, jq.
set -euo pipefail

BUILT_DIR="${1:-}"
BUCKET="${2:-}"
ENDPOINT="${3:-}"
REMOVED_LIST="${4:-}"

if [ -z "$BUILT_DIR" ] || [ -z "$BUCKET" ] || [ -z "$ENDPOINT" ]; then
	echo "usage: prune-installers.sh <built-install-dir> <bucket> <endpoint> [<removed-list>]" >&2
	exit 2
fi

# The prefix the installers live under. It is a constant of the archive layout
# rather than an argument: a prune that could be pointed at another prefix
# would be a prune that could delete the metadata.
PREFIX="install/"

case "$BUCKET" in
	*[!a-z0-9.-]* | '')
		echo "::error::the bucket must be a plain name, got '$BUCKET'" >&2
		exit 2
		;;
esac

# What this run built. The prune means "the bucket keeps exactly this", so an
# empty build is a broken build: pruning against it would empty the archive.
[ -d "$BUILT_DIR" ] \
	|| { echo "::error::no built installer directory at $BUILT_DIR" >&2; exit 1; }
built="$(find "$BUILT_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort -u)"
[ -n "$built" ] \
	|| { echo "::error::no bootstrap installer was built at $BUILT_DIR; refusing to prune the served ones against an empty build" >&2; exit 1; }

# Is this the name of an installer this run built?
is_built() { # $1 = the name under install/
	printf '%s\n' "$built" | grep -qxF -- "$1"
}

# The keys the bucket serves under the prefix, one per line.
#
# The S3 API rather than `aws s3 ls`, for two reasons: it says exactly which
# keys exist, and it says whether the listing was truncated. A truncated page
# has to be refused rather than read as a complete view, because a prune
# against a partial listing would leave behind the very leftovers it was sent
# to remove.
list_installers() {
	local json
	json="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" \
		--endpoint-url "$ENDPOINT" --output json)"
	if [ "$(printf '%s' "$json" | jq -r '.IsTruncated // false')" != "false" ]; then
		echo "::error::the listing of $BUCKET$PREFIX is truncated; refusing to prune a partial view of the bucket" >&2
		exit 1
	fi
	printf '%s' "$json" | jq -r '.Contents[]?.Key'
}

served="$(list_installers)"

# The served installers this run did not build. Those are the products that
# left the roster.
removed=""
while IFS= read -r key; do
	[ -n "$key" ] || continue
	case "$key" in
		"$PREFIX"*) ;;
		*)
			echo "::error::the listing returned '$key', which is not under $PREFIX; refusing to touch it" >&2
			exit 1
			;;
	esac
	is_built "${key#"$PREFIX"}" || removed="$removed$key
"
done <<< "$served"

if [ -n "$removed" ]; then
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		# One call per object, and the key is one argument: `aws s3 rm` takes
		# it as a URI, where a name with a space would arrive as two.
		aws s3api delete-object --bucket "$BUCKET" --key "$key" \
			--endpoint-url "$ENDPOINT" >/dev/null
		echo "pruned $key"
	done <<< "$removed"
else
	echo "no installer to prune: the bucket serves exactly the installers this run built"
fi

# The paths the edge purge has to cover. The edge holds an installer for a day
# (they are served with max-age=86400), so removing the object from the
# bucket is not enough: without a purge of that URL the edge keeps handing
# out the script of a product that no longer exists.
#
# The list is written here rather than derived by the purge because the
# objects are already gone by the time the edge is purged: there is nothing
# left to list.
if [ -n "$REMOVED_LIST" ]; then
	printf '%s' "$removed" > "$REMOVED_LIST"
fi

# Read the bucket back. A prune that removed nothing and reported nothing is
# the failure this script exists to fix, and the only way to know it took
# effect is to look: what the bucket serves has to be exactly what was built.
after="$(list_installers)"
leftover=""
while IFS= read -r key; do
	[ -n "$key" ] || continue
	case "$key" in
		"$PREFIX"*) ;;
		*)
			echo "::error::the bucket returned '$key', which is not under $PREFIX" >&2
			exit 1
			;;
	esac
	is_built "${key#"$PREFIX"}" || leftover="$leftover$key
"
done <<< "$after"

if [ -n "$leftover" ]; then
	echo "::error::the bucket still serves installers this run did not build:" >&2
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		echo "  $key" >&2
	done <<< "$leftover"
	exit 1
fi

echo "the bucket serves exactly the $(printf '%s\n' "$built" | wc -l) installer(s) this run built"
