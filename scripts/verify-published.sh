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
# Fails closed: an unverifiable signature, a malformed index, an unreachable
# file or any size/hash mismatch is a non-zero exit, so the publish goes red
# rather than reporting success over a broken archive.
#
# Retries before failing. The observed cause of the 404 was a visibility lag
# between the R2 write and the read rather than anything the pipeline got wrong,
# and the Cloudflare purge that precedes this check is asynchronous too. A gate
# that goes red on a condition which resolves itself seconds later is a gate
# that gets ignored, so mismatches are re-read on a bounded schedule and only a
# mismatch that never converges fails the run.
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
MAX_ENTRIES=200

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

# fetch <url> <destination>
# Transport-level retries only. An HTTP error is retried too (--retry-all-errors
# with -f), which absorbs a brief 404 while an object becomes visible; the
# caller's own retry loop handles a lag longer than that.
fetch() {
	curl -fsS --retry 3 --retry-all-errors --retry-delay 2 --max-time 60 \
		--max-filesize "$MAX_INDEX_BYTES" "$1" -o "$2"
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

# check_entry <sha256> <size> <path>
# Fetches one declared file and compares it against the declaration. Prints a
# diagnostic and returns non-zero on any disagreement.
check_entry() {
	local want_hash="$1" want_size="$2" path="$3"
	local url="$BASE_URL/$DIST_PATH/$path"
	local dest="$WORK/served"
	local got_hash got_size

	rm -f "$dest"
	if ! fetch "$url" "$dest"; then
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
	return 0
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

mapfile -t entries < <(declared_files "$WORK/InRelease.body")
if [ "${#entries[@]}" -eq 0 ]; then
	echo "::error::the signed index declares no SHA256 entries — it is malformed" >&2
	exit 1
fi
if [ "${#entries[@]}" -gt "$MAX_ENTRIES" ]; then
	echo "::error::the signed index declares ${#entries[@]} files, over the $MAX_ENTRIES cap" >&2
	exit 1
fi

# The paths come from a signed document, so they are authentic — but authentic
# is not the same as safe, and the key that signs them is the one thing whose
# compromise this script cannot detect. Reject anything that is not a plain
# relative path before it is pasted into a URL.
for entry in "${entries[@]}"; do
	path="${entry##* }"
	case "$path" in
		*/../* | ../* | */.. | /* | *//*)
			echo "::error::the signed index declares a path that is not a plain relative path: $path" >&2
			exit 1
			;;
	esac
	case "$path" in
		*[!A-Za-z0-9._/-]*)
			echo "::error::the signed index declares a path with unexpected characters: $path" >&2
			exit 1
			;;
	esac
done

echo "the signed index declares ${#entries[@]} file(s)"

# --- Compare served against signed, retrying a lag ---------------------------

pending=("${entries[@]}")
attempt=1
while :; do
	failed=()
	for entry in "${pending[@]}"; do
		read -r entry_hash entry_size entry_path <<< "$entry"
		if ! check_entry "$entry_hash" "$entry_size" "$entry_path"; then
			failed+=("$entry")
		fi
	done

	if [ "${#failed[@]}" -eq 0 ]; then
		break
	fi
	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		echo "::error::${#failed[@]} of ${#entries[@]} file(s) declared by the signed index are not being served as signed, after $attempt attempt(s)" >&2
		for entry in "${failed[@]}"; do
			echo "::error::  ${entry##* }" >&2
		done
		exit 1
	fi

	echo "attempt $attempt/$ATTEMPTS: ${#failed[@]} file(s) not yet consistent, re-reading in ${DELAY}s"
	sleep "$DELAY"
	pending=("${failed[@]}")
	attempt=$((attempt + 1))
done

echo "all ${#entries[@]} declared file(s) are served exactly as signed"
