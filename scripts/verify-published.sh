#!/usr/bin/env bash
#
# Verify that the archive being served matches the archive that was signed.
#
# The publish pipeline verifies every product .deb before admitting it, and then
# uploads the result without ever asking whether what it published is actually
# reachable. It is not: a publish has finished green with the signed InRelease
# declaring an index file that returned 404 (see issue #47), and the archive
# stayed that way until the next scheduled run. This script closes that gap by
# reading the live archive back and comparing it against its own signature.
#
# The signed index is the source of truth for what must exist. Every file it
# declares is fetched from the live URL and checked for exact size and SHA256.
# Nothing here is derived from a list written by hand, so an index file that
# reprepro starts or stops emitting is picked up with no change to this script.
#
# The whole signed chain is walked, not just its first link:
#
#   InRelease (signed by the archive key)
#     -> main/binary-<arch>/Packages   (size + SHA256 declared in InRelease)
#       -> pool/**/*.deb               (size + SHA256 declared in Packages)
#
# Stopping at the indices would read as a stronger guarantee than it is. A
# missing uncompressed Packages breaks only clients that do not prefer the .gz;
# a missing .deb breaks apt install for everyone.
#
# Fails closed: an unverifiable signature, a malformed index, an unreachable
# file or any size/hash mismatch is a non-zero exit, so the publish goes red
# rather than reporting success over a broken archive.
#
# Retries before failing, because the Cloudflare purge that precedes this check
# is asynchronous: a gate that goes red on a condition which clears itself
# seconds later is a gate that gets ignored. Mismatches are re-read on a bounded
# schedule and only one that never converges fails the run.
#
# That is the ONLY thing the retry buys, and the schedule (6 x 10 s by default)
# is not measured — nobody has timed how long an edge purge takes to propagate.
# It was originally also justified by a write-then-read visibility lag in R2,
# which turned out not to exist: #47's object was deleted by the publish racing
# itself, not briefly invisible (#53). Retrying a deleted object only fails
# slower. If the retry ever needs re-tuning, measure the purge; do not reason
# from the lag.
#
# Trust rests on the archive public key, never on the transport: an http:// base
# URL is accepted (the test suite serves one locally) because TLS is not what
# makes the answer trustworthy here — the signature is.
#
# Requires: curl, gpg, sha256sum.
#
# Usage:
#   verify-published.sh <base-url> [<pubkey-asc>] [<attempts>] [<delay-seconds>]

set -euo pipefail

BASE_URL="${1:?usage: verify-published.sh <base-url> [<pubkey-asc>] [<attempts>] [<delay-seconds>]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBKEY_ASC="${2:-$HERE/keyring/glyndor-apt-key.asc}"
ATTEMPTS="${3:-6}"
DELAY="${4:-10}"

# Strip a trailing slash so the URLs built below never contain a double one;
# some edges treat "//dists" as a distinct, uncached path.
BASE_URL="${BASE_URL%/}"
DIST_PATH="dists/stable"

# An index file is metadata, not a package. The cap is far above any plausible
# Packages file and exists so a wrong or hostile object cannot fill the runner's
# disk before the size comparison below ever gets to reject it.
MAX_INDEX_BYTES=$((64 * 1024 * 1024))
# A bound on how many files the index may declare, for the same reason: the
# signed body is authentic, but authenticity is not a size limit.
# Overridable from the environment so the suite can exercise the cap on a
# small archive; production never sets it and gets the default.
MAX_ENTRIES="${VERIFY_PUBLISHED_MAX_ENTRIES:-200}"
# A package is a real binary, so it gets its own, larger per-object cap — kept
# in step with the per-.deb cap publish.yml enforces on the way in.
MAX_POOL_OBJECT_BYTES=$((300 * 1024 * 1024))
# And a budget for the whole pool. The archive is latest-only, so this grows
# with the number of products rather than with time; blowing through it means
# the check needs redesigning, which should be an error and not a slow publish.
MAX_POOL_BYTES="${VERIFY_PUBLISHED_MAX_POOL_BYTES:-$((2 * 1024 * 1024 * 1024))}"

case "$ATTEMPTS" in '' | *[!0-9]*) echo "::error::attempts must be a positive integer, got '$ATTEMPTS'" >&2; exit 1 ;; esac
case "$DELAY" in '' | *[!0-9]*) echo "::error::delay must be a non-negative integer, got '$DELAY'" >&2; exit 1 ;; esac
[ "$ATTEMPTS" -ge 1 ] || { echo "::error::attempts must be at least 1" >&2; exit 1; }
[ -f "$PUBKEY_ASC" ] || { echo "::error::archive public key $PUBKEY_ASC not found" >&2; exit 1; }

WORK="$(mktemp -d)"
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() {
	gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	rm -rf "$WORK" "$GNUPGHOME"
}
trap cleanup EXIT

gpg --batch --quiet --import "$PUBKEY_ASC" \
	|| { echo "::error::could not import the archive public key from $PUBKEY_ASC" >&2; exit 1; }

# fetch <url> <destination> [<max-bytes>]
# Transport-level retries only. An HTTP error is retried too (--retry-all-errors
# with -f), which absorbs a brief 404 while an object becomes visible; the
# caller's own retry loop handles a lag longer than that.
fetch() {
	curl -fsS --retry 3 --retry-all-errors --retry-delay 2 --max-time 300 \
		--max-filesize "${3:-$MAX_INDEX_BYTES}" "$1" -o "$2"
}

# verify_clearsigned <clearsigned-file> <output-body>
# Writes the cryptographically verified body, so everything parsed downstream
# is what the archive key actually signed.
verify_clearsigned() {
	gpg --batch --yes --output "$2" --decrypt "$1" 2>/dev/null
}

# sha256_of <file>
sha256_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# declared_files <verified-index-body>
# Emits "<sha256> <size> <path>" for every entry in the index's SHA256 section.
# The section runs from the "SHA256:" header to the next line that does not
# start with whitespace, which is what keeps the PGP armour and the other digest
# sections (MD5Sum, SHA1) out of the result.
declared_files() {
	awk '
		/^SHA256:/ { in_section = 1; next }
		/^[^[:space:]]/ { in_section = 0 }
		in_section && NF == 3 { print $1, $2, $3 }
	' "$1"
}

# declared_packages <verified-Packages-file>
# Emits "<sha256> <size> <path>" for every package stanza. This is the third
# link of the chain: the signed index vouches for these Packages bytes, and
# these Packages bytes vouch for the .deb files an apt client actually installs.
declared_packages() {
	awk '
		/^Filename:/ { filename = $2 }
		/^Size:/ { size = $2 }
		/^SHA256:/ { hash = $2 }
		/^[[:space:]]*$/ {
			if (filename != "") { print hash, size, filename }
			filename = ""; size = ""; hash = ""
		}
		END { if (filename != "") { print hash, size, filename } }
	' "$1"
}

# reject_unsafe_paths <label> <entries-file>
# The paths come from a signed document, so they are authentic — but authentic
# is not the same as safe, and the key that signs them is the one thing this
# script cannot detect the compromise of. Reject anything that is not a plain
# relative path before it is pasted into a URL or used as a filename.
reject_unsafe_paths() {
	local label="$1" path
	while read -r _ _ path; do
		case "$path" in
			*/../* | ../* | */.. | /* | *//*)
				echo "::error::the $label declares a path that is not a plain relative path: $path" >&2
				exit 1
				;;
		esac
		case "$path" in
			*[!A-Za-z0-9._/+~-]*)
				echo "::error::the $label declares a path with unexpected characters: $path" >&2
				exit 1
				;;
		esac
	done < "$2"
}

# check_entry <sha256> <size> <path> <url-prefix> <max-bytes> <save-dir>
# Fetches one declared file and compares it against the declaration. On success
# the verified bytes are kept under save-dir, so a later stage can parse exactly
# what was checked rather than re-downloading and re-opening the gap between
# what was verified and what was used. Prints a diagnostic and returns non-zero
# on any disagreement.
check_entry() {
	local want_hash="$1" want_size="$2" path="$3" prefix="$4" max_bytes="$5" save_dir="$6"
	local url="$BASE_URL${prefix:+/$prefix}/$path"
	local dest="$WORK/served"
	local got_hash got_size

	rm -f "$dest"
	if ! fetch "$url" "$dest" "$max_bytes"; then
		echo "  unreachable: $path"
		return 1
	fi
	got_size="$(stat -c%s "$dest")"
	if [ "$got_size" != "$want_size" ]; then
		echo "  size mismatch: $path (signed $want_size, served $got_size)"
		return 1
	fi
	got_hash="$(sha256_of "$dest")"
	if [ "$got_hash" != "$want_hash" ]; then
		echo "  hash mismatch: $path (signed $want_hash, served $got_hash)"
		return 1
	fi
	if [ -n "$save_dir" ]; then
		mkdir -p "$save_dir"
		mv "$dest" "$save_dir/${path//\//_}"
	fi
	return 0
}

# verify_set <label> <entries-file> <url-prefix> <max-bytes> <save-dir>
# Checks every entry, re-reading only the ones that disagree, on a bounded
# schedule. Exits non-zero once they stop converging.
verify_set() {
	local label="$1" entries_file="$2" prefix="$3" max_bytes="$4" save_dir="$5"
	local -a pending failed
	local attempt=1 entry entry_hash entry_size entry_path total

	mapfile -t pending < "$entries_file"
	total="${#pending[@]}"

	while :; do
		failed=()
		for entry in "${pending[@]}"; do
			read -r entry_hash entry_size entry_path <<< "$entry"
			if ! check_entry "$entry_hash" "$entry_size" "$entry_path" \
				"$prefix" "$max_bytes" "$save_dir"; then
				failed+=("$entry")
			fi
		done

		if [ "${#failed[@]}" -eq 0 ]; then
			break
		fi
		if [ "$attempt" -ge "$ATTEMPTS" ]; then
			echo "::error::${#failed[@]} of $total $label are not being served as signed, after $attempt attempt(s)" >&2
			for entry in "${failed[@]}"; do
				echo "::error::  ${entry##* }" >&2
			done
			exit 1
		fi

		echo "attempt $attempt/$ATTEMPTS: ${#failed[@]} $label not yet consistent, re-reading in ${DELAY}s"
		sleep "$DELAY"
		pending=("${failed[@]}")
		attempt=$((attempt + 1))
	done

	echo "all $total $label are served exactly as signed"
}

echo "verifying the archive served at $BASE_URL against its signed index"

# --- The signed index itself -------------------------------------------------

if ! fetch "$BASE_URL/$DIST_PATH/InRelease" "$WORK/InRelease"; then
	echo "::error::could not fetch $BASE_URL/$DIST_PATH/InRelease" >&2
	exit 1
fi
if ! verify_clearsigned "$WORK/InRelease" "$WORK/InRelease.body"; then
	echo "::error::InRelease signature verification failed — the served index is unsigned or signed by an untrusted key" >&2
	exit 1
fi

# The detached pair apt falls back to when it does not use InRelease. A stale
# Release would declare hashes the current archive no longer serves, so check
# that it verifies and that it agrees with InRelease rather than assuming the
# sync uploaded both halves of the same build.
if ! fetch "$BASE_URL/$DIST_PATH/Release" "$WORK/Release" \
	|| ! fetch "$BASE_URL/$DIST_PATH/Release.gpg" "$WORK/Release.gpg"; then
	echo "::error::could not fetch the detached Release / Release.gpg pair" >&2
	exit 1
fi
if ! gpg --batch --verify "$WORK/Release.gpg" "$WORK/Release" 2>/dev/null; then
	echo "::error::Release.gpg does not verify against Release — the detached pair is stale or untrusted" >&2
	exit 1
fi
if ! diff -q <(declared_files "$WORK/InRelease.body") <(declared_files "$WORK/Release") >/dev/null; then
	echo "::error::Release and InRelease declare different files — the archive is serving two different builds" >&2
	exit 1
fi

# --- What the index declares -------------------------------------------------

declared_files "$WORK/InRelease.body" > "$WORK/index-entries"
index_count="$(wc -l < "$WORK/index-entries")"
if [ "$index_count" -eq 0 ]; then
	echo "::error::the signed index declares no SHA256 entries — it is malformed" >&2
	exit 1
fi
if [ "$index_count" -gt "$MAX_ENTRIES" ]; then
	echo "::error::the signed index declares $index_count files, over the $MAX_ENTRIES cap" >&2
	exit 1
fi
reject_unsafe_paths "signed index" "$WORK/index-entries"

echo "the signed index declares $index_count index file(s)"
verify_set "index file(s)" "$WORK/index-entries" "$DIST_PATH" "$MAX_INDEX_BYTES" "$WORK/indices"

# --- What the verified indices declare ---------------------------------------

# The chain does not end at the indices. Each Packages file declares the .deb an
# apt client actually installs, with its size and SHA256, and that is the object
# whose absence breaks every client rather than a subset. Parse the Packages
# bytes that were just verified above, never a fresh download, or the gap
# between what was checked and what was used reopens here.
#
# Pool objects are served under a one-year immutable cache. They used to be
# left out of the publish's purge, which meant a bad edge copy could outlast a
# bad index by a year AND could not be cleared by publishing again; #59 added
# them to the purge, so a bad edge copy is now bounded by the publish cadence
# like everything else. A wrong object in R2 itself is still only fixed by the
# next correct upload — purging does not conjure the right bytes.
#
# Deduplicate: an architecture-independent package (the keyring) is declared in
# every architecture's Packages, and fetching it once per architecture proves
# nothing extra.
: > "$WORK/pool-entries"
shopt -s nullglob
for index in "$WORK"/indices/*_Packages; do
	declared_packages "$index" >> "$WORK/pool-entries"
done
shopt -u nullglob
LC_ALL=C sort -u -o "$WORK/pool-entries" "$WORK/pool-entries"

pool_count="$(wc -l < "$WORK/pool-entries")"
if [ "$pool_count" -eq 0 ]; then
	echo "::error::the verified indices declare no packages — an archive serving no installable package is broken" >&2
	exit 1
fi
if [ "$pool_count" -gt "$MAX_ENTRIES" ]; then
	echo "::error::the verified indices declare $pool_count packages, over the $MAX_ENTRIES cap" >&2
	exit 1
fi
reject_unsafe_paths "verified indices" "$WORK/pool-entries"

# The declaration is authentic, not a budget. Cap the total so the archive
# outgrowing what this check can afford to download fails loudly here rather
# than quietly turning every publish into a long transfer.
pool_bytes="$(awk '{ total += $2 } END { print total + 0 }' "$WORK/pool-entries")"
if [ "$pool_bytes" -gt "$MAX_POOL_BYTES" ]; then
	echo "::error::the verified indices declare $pool_bytes bytes of packages, over the $MAX_POOL_BYTES cap; this check needs to move to ranged or sampled reads" >&2
	exit 1
fi

echo "the verified indices declare $pool_count package(s), $pool_bytes byte(s)"
verify_set "package(s)" "$WORK/pool-entries" "" "$MAX_POOL_OBJECT_BYTES" ""
