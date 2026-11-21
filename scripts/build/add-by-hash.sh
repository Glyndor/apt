#!/usr/bin/env bash
#
# Offer the index of a distribution by hash, then sign it.
#
# apt reads InRelease and then asks for each index file it declares. Without
# `Acquire-By-Hash: yes` it asks for the fixed name, main/binary-amd64/Packages,
# so a client that read the InRelease of one publish and asks for Packages after
# the next publish has replaced it receives bytes whose hash is not the one its
# InRelease declares, and `apt update` fails with "Hash Sum mismatch". With the
# field, apt asks for main/binary-amd64/by-hash/SHA256/<the hash it read>, and
# that name holds the same bytes for as long as it exists.
#
# reprepro writes neither the field nor the copies (5.3.2, the version the
# ubuntu-26.04 runner installs, has no option for either, and no way to add a
# field to the Release it writes). So build-repo.sh has reprepro export the
# distribution unsigned and this script does the rest: it copies every file the
# Release declares under SHA256 to <its directory>/by-hash/SHA256/<sha256>,
# adds the field, and signs. The field has to be inside what is signed, or a
# client could not trust it, which is why the signature is made here and not by
# reprepro.
#
# Every step fails closed. A copy is made only of bytes whose size and SHA256
# are the ones the Release declares. The signatures are made with the key
# build-repo.sh imported and checked, then verified against the committed public
# key, and the body of InRelease is compared with Release, so what is written is
# what a client verifies.
#
# Usage: add-by-hash.sh <dists/<suite> directory> <signing key fingerprint> <public key .asc>
# Requires: gpg, gpgv, sha256sum; GNUPGHOME holding the secret key.
set -euo pipefail

DIST="${1:-}"
FPR="${2:-}"
PUBKEY_ASC="${3:-}"
if [ -z "$DIST" ] || [ -z "$FPR" ] || [ -z "$PUBKEY_ASC" ]; then
	echo "usage: add-by-hash.sh <dists/<suite> directory> <signing key fingerprint> <public key .asc>" >&2
	exit 2
fi
RELEASE="$DIST/Release"
[ -f "$RELEASE" ] || { echo "::error::no Release at $RELEASE" >&2; exit 1; }
[ -f "$PUBKEY_ASC" ] || { echo "::error::no public key at $PUBKEY_ASC" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The SHA256 list of the Release: ` <sha256> <size> <path>` lines under the
# `SHA256:` field, which ends at the next line that does not start with a space.
awk '/^SHA256:/ { inside = 1; next } /^[^ ]/ { inside = 0 } inside' "$RELEASE" > "$WORK/entries"
if [ ! -s "$WORK/entries" ]; then
	echo "::error::$RELEASE declares no SHA256 entries, so there is nothing to offer by hash" >&2
	exit 1
fi

count=0
while read -r sha size path rest; do
	if [ -n "$rest" ] || ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
		echo "::error::$RELEASE has a SHA256 line that is not '<sha256> <size> <path>': $sha $size $path $rest" >&2
		exit 1
	fi
	# A path named by-hash, or under one, is refused: it is where the copies
	# go, and a file of that name would also stop the directory being made.
	case "$path" in
		'' | . | .. | ./* | */./* | */. | */../* | ../* | */.. | /* | *//* | *[!A-Za-z0-9._/+~-]* | by-hash | */by-hash | by-hash/* | */by-hash/*)
			echo "::error::$RELEASE declares a path that is not a plain relative index path: $path" >&2
			exit 1 ;;
	esac
	file="$DIST/$path"
	if [ ! -f "$file" ]; then
		echo "::error::$RELEASE declares $path, which is not in $DIST" >&2
		exit 1
	fi
	if [ "$(stat -c%s "$file")" != "$size" ] || [ "$(sha256sum < "$file" | cut -d' ' -f1)" != "$sha" ]; then
		echo "::error::$path is not the file $RELEASE declares (size $size, SHA256 $sha)" >&2
		exit 1
	fi
	dir="$(dirname "$file")/by-hash/SHA256"
	mkdir -p "$dir"
	cp "$file" "$dir/$sha"
	count=$((count + 1))
done < "$WORK/entries"

# The field goes into the paragraph, before the first checksum list; there is
# one, the SHA256 list read above. reprepro does not write the field today; if
# a later version does, the line it writes has to be the one this script would
# write, or the run stops rather than signing two answers to one question.
present="$(grep -c '^Acquire-By-Hash:' "$RELEASE" || true)"
if [ "$present" -eq 0 ]; then
	awk '!done && /^(MD5Sum|SHA1|SHA256|SHA512):/ { print "Acquire-By-Hash: yes"; done = 1 } { print }' \
		"$RELEASE" > "$WORK/Release"
	cat "$WORK/Release" > "$RELEASE"
elif [ "$present" -ne 1 ] || ! grep -qx 'Acquire-By-Hash: yes' "$RELEASE"; then
	echo "::error::$RELEASE already carries an Acquire-By-Hash field that is not 'Acquire-By-Hash: yes'" >&2
	exit 1
fi

# Signed into the work directory and moved into place only once both
# signatures verify, so a refusal below leaves no signed index behind.
rm -f "$DIST/InRelease" "$DIST/Release.gpg"
gpg --batch --yes --local-user "$FPR" --digest-algo SHA512 --clearsign \
	--output "$WORK/InRelease" "$RELEASE"
gpg --batch --yes --local-user "$FPR" --digest-algo SHA512 --armor --detach-sign \
	--output "$WORK/Release.gpg" "$RELEASE"

# Read the signatures back with the key clients are given, not the keyring that
# made them: a signature only the signing keyring accepts is one no client does.
gpg --batch --quiet --dearmor --output "$WORK/archive-key.gpg" "$PUBKEY_ASC"
# What gpgv says is kept and added to the refusal, since it is what tells a
# signature by another key from a public key file that cannot be read.
gpgv_said() { tr '\n' ' ' < "$WORK/gpgv.err" | sed 's/ *$//'; }
if ! gpgv --keyring "$WORK/archive-key.gpg" --quiet --output "$WORK/body" "$WORK/InRelease" 2>"$WORK/gpgv.err" \
	|| ! cmp -s "$WORK/body" "$RELEASE"; then
	echo "::error::the InRelease just signed does not verify against $PUBKEY_ASC, or its body is not the Release; gpgv said: $(gpgv_said)" >&2
	exit 1
fi
if ! gpgv --keyring "$WORK/archive-key.gpg" --quiet "$WORK/Release.gpg" "$RELEASE" 2>"$WORK/gpgv.err"; then
	echo "::error::the Release.gpg just signed does not verify against $PUBKEY_ASC; gpgv said: $(gpgv_said)" >&2
	exit 1
fi
mv "$WORK/InRelease" "$WORK/Release.gpg" "$DIST/"

echo "offered $count index file(s) by hash under $DIST and signed the index with $FPR"
