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
while IFS= read -r -d '' name; do
	case "$name" in
		*[$'\001'-$'\037'$'\177']*) echo "::error::invalid built installer name" >&2; exit 1 ;;
	esac
done < <(find "$BUILT_DIR" -maxdepth 1 -type f -printf '%f\0')
built="$(find "$BUILT_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort -u)"
[ -n "$built" ] \
	|| { echo "::error::no bootstrap installer was built at $BUILT_DIR; refusing to prune the served ones against an empty build" >&2; exit 1; }

# Is this the name of an installer this run built?
is_built() { # $1 = the name under install/
	grep -qxF -- "$1" <<< "$built"
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
		--endpoint-url "$ENDPOINT" --output json --no-paginate)"
	if ! jq -se 'length == 1 and (.[0] | type == "object" and .IsTruncated == false)' <<< "$json" >/dev/null; then
		echo "::error::the listing of $BUCKET/$PREFIX is not complete; refusing to prune a partial view" >&2
		exit 1
	fi
	# Validate before decoding to lines: a newline in a key must not become
	# two deletion candidates, and malformed Contents must not mean empty.
	if ! jq -e '(if has("Contents") then .Contents else [] end) | type == "array" and all(.[];
		(.Key | type == "string") and
		(.Key | length > 0) and
		(.Key | explode | all(.[]; . >= 32 and . != 127)))' <<< "$json" >/dev/null; then
		echo "::error::invalid installer listing" >&2
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
		"$PREFIX"*)
			case "$key" in
				*..* | *'//'*) echo "::error::unsafe installer key: $key" >&2; exit 1 ;;
			esac
			;;
		*)
			echo "::error::the listing returned '$key', which is not under $PREFIX; refusing to touch it" >&2
			exit 1
			;;
	esac
	is_built "${key#"$PREFIX"}" || removed="$removed$key
"
done <<< "$served"

# Every built installer must already be served: publish metadata first.
# An empty (but complete) listing authorizes no deletion and is a failed publish.
require_built() {
	local name
	while IFS= read -r name; do
		grep -qxF -- "$PREFIX$name" <<< "$1" || {
			echo "::error::built installer is missing from the bucket: $name" >&2
			exit 1
		}
	done <<< "$built"
}
require_built "$served"

# Journal the planned deletes before any destructive call. A failed response
# may follow a visible delete; retain earlier attempts when this tree is retried.
if [ -n "$REMOVED_LIST" ]; then
	if [ -e "$REMOVED_LIST" ] && [ ! -f "$REMOVED_LIST" ]; then
		echo "::error::cannot write removed paths at $REMOVED_LIST" >&2; exit 1
	fi
	previous=""
	if [ -e "$REMOVED_LIST" ]; then
		previous="$(cat "$REMOVED_LIST")"
		while IFS= read -r key; do
			[ -n "$key" ] || continue
			case "$key" in
				install/*) ;;
				*) echo "::error::invalid removed paths journal" >&2; exit 1 ;;
			esac
			case "$key" in
				*..* | *'//'* | *[$'\001'-$'\037'$'\177']*)
					echo "::error::unsafe removed paths journal" >&2; exit 1 ;;
			esac
		done <<< "$previous"
	fi
	journal_tmp="$(mktemp "${REMOVED_LIST}.XXXXXX")"
	trap 'rm -f "$journal_tmp"' EXIT
	printf '%s\n%s' "$previous" "$removed" | sed '/^$/d' | LC_ALL=C sort -u > "$journal_tmp"
	mv -- "$journal_tmp" "$REMOVED_LIST"
fi

if [ -n "$removed" ]; then
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		# Keep each exact key in one argument; never use recursive prefix removal.
		aws s3api delete-object --bucket "$BUCKET" --key "$key" \
			--endpoint-url "$ENDPOINT" >/dev/null
		echo "pruned $key"
	done <<< "$removed"
else
	echo "no installer to prune: the bucket serves exactly the installers this run built"
fi

# Read the bucket back. A prune that removed nothing and reported nothing is
# the failure this script exists to fix, and the only way to know it took
# effect is to look: what the bucket serves has to be exactly what was built.
after="$(list_installers)"
require_built "$after"
leftover=""
while IFS= read -r key; do
	[ -n "$key" ] || continue
	case "$key" in
		"$PREFIX"*)
			case "$key" in
				*..* | *'//'*) echo "::error::unsafe installer key: $key" >&2; exit 1 ;;
			esac
			;;
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
