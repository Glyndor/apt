#!/usr/bin/env bash
#
# Build the signed Glyndor apt repository into a directory ready to publish to
# Cloudflare R2 (apt.glyndor.net). The repository is rebuilt fresh on every run from
# the current release of each product, so it always carries exactly the latest
# version of every package; Glyndor ships no old-version support.
#
# Requires: reprepro, gpg, gpgv, and dpkg-deb with --bootstrap.
# Reads the armored private signing key from $GLYNDOR_APT_GPG_PRIVATE_KEY.
#
# Usage:
#   GLYNDOR_APT_GPG_PRIVATE_KEY="$(cat priv.asc)" \
#     build-repo.sh [--bootstrap <keyring-deb>] <output-dir> <deb> [<deb> ...]
#
# With --bootstrap, the keyring package is also served at the root of the
# output directory as glyndor-archive-keyring.deb, for the first install that
# happens before apt knows the archive, with a detached signature beside it,
# glyndor-archive-keyring.deb.asc, which the bootstrap installer requires. The
# signature is made here, with the key imported and checked below for the index,
# so the secret is imported once and the key that signs is chosen once: a second
# import elsewhere would need its own copy of every check on the key, and a
# copy that nothing reaches is a check that can be deleted with every suite
# green.

set -euo pipefail

BOOTSTRAP=""
if [ "${1:-}" = "--bootstrap" ]; then
	BOOTSTRAP="${2:?--bootstrap needs the keyring package to serve}"
	shift 2
	[ -f "$BOOTSTRAP" ] || { echo "no such keyring package: $BOOTSTRAP" >&2; exit 1; }
	# Whatever is given is served under the keyring's name and signed with the
	# archive key, so it has to be the keyring package: by its file name, the
	# one build-keyring.sh writes, and by its control field. The package is
	# built locally a step earlier, so reading it is not reading a download.
	[ "$(basename "$BOOTSTRAP")" = glyndor-archive-keyring.deb ] \
		|| { echo "::error::--bootstrap takes glyndor-archive-keyring.deb, not $(basename "$BOOTSTRAP")" >&2; exit 1; }
	[ "$(dpkg-deb -f "$BOOTSTRAP" Package 2>/dev/null)" = glyndor-archive-keyring ] \
		|| { echo "::error::$BOOTSTRAP is not the glyndor-archive-keyring package" >&2; exit 1; }
	BOOTSTRAP="$(cd "$(dirname "$BOOTSTRAP")" && pwd)/$(basename "$BOOTSTRAP")"
fi

OUT_DIR="${1:?usage: build-repo.sh [--bootstrap <keyring-deb>] <output-dir> <deb> [<deb> ...]}"
shift
[ "$#" -ge 1 ] || { echo "no .deb files given" >&2; exit 1; }

: "${GLYNDOR_APT_GPG_PRIVATE_KEY:?GLYNDOR_APT_GPG_PRIVATE_KEY is not set}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBKEY_ASC="$HERE/keyring/glyndor-apt-key.asc"
[ -f "$PUBKEY_ASC" ] || { echo "missing public key: $PUBKEY_ASC" >&2; exit 1; }

DEBS=()
for d in "$@"; do
	[ -f "$d" ] || { echo "no such .deb: $d" >&2; exit 1; }
	DEBS+=("$(cd "$(dirname "$d")" && pwd)/$(basename "$d")")
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() { timeout 10 gpgconf --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"; }
trap cleanup EXIT

# Import the signing key. Don't swallow import errors: if the secret is
# malformed the failure must be diagnosable, not silent.
printf '%s' "$GLYNDOR_APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import

# The key now lives in the ephemeral GNUPGHOME above; nothing past this point
# needs it in the environment, and no child process (or a stray debug trace)
# should be able to read the private key out of this shell's env after import.
unset GLYNDOR_APT_GPG_PRIVATE_KEY

# Require exactly one secret key. If the secret ever carried more than one (e.g.
# old + new pasted in during a rotation), the first-fingerprint pick below would
# sign with whichever imported first, not necessarily the intended active key,
# and the index and the bootstrap package would both be signed by it.
# `grep -c` exits 1 on zero matches, which pipefail would turn into a silent
# death inside the substitution, so guard it and let the count (0) reach the
# diagnostic below instead.
SEC_COUNT="$(gpg --batch --with-colons --list-secret-keys | { grep -c '^sec:' || true; })"
[ "$SEC_COUNT" -eq 1 ] || { echo "::error::expected exactly one secret key in GLYNDOR_APT_GPG_PRIVATE_KEY, found $SEC_COUNT" >&2; exit 1; }

FPR="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || { echo "could not determine signing key fingerprint" >&2; exit 1; }

# Fail closed unless the signing secret's key is one of those shipped in the
# committed public keyring. The .asc may carry more than one key during a
# two-phase rotation (old + new in the overlap), so match the secret against
# every key in it, not just the first.
if ! gpg --batch --with-colons --show-keys "$PUBKEY_ASC" \
	| awk -F: '/^fpr:/{print $10}' | grep -qxF "$FPR"; then
	echo "::error::signing key ($FPR) is not present in $PUBKEY_ASC" >&2
	exit 1
fi

CONF="$OUT_DIR/conf"
mkdir -p "$CONF"
cat > "$CONF/distributions" <<EOF
Origin: Glyndor
Label: Glyndor
Suite: stable
Codename: stable
Architectures: amd64 arm64
Components: main
Description: Glyndor apt repository
# Stamp an expiry on the signed Release (Valid-Until). The daily schedule
# re-signs and re-stamps it; apt rejects an expired index, so a stalled
# publish or a frozen cache can't silently pin clients to a stale package
# list. The window is wider than the daily cadence so a few missed builds
# don't break clients.
ValidFor: 14d
EOF
# No SignWith: reprepro exports the distribution unsigned, and add-by-hash.sh
# adds `Acquire-By-Hash: yes` and the by-hash copies of every index file, then
# signs InRelease and Release.gpg with the key checked above. reprepro has no
# option for either, and the field has to be inside the signature.

reprepro -b "$OUT_DIR" includedeb stable "${DEBS[@]}"
"$(dirname "$0")/add-by-hash.sh" "$OUT_DIR/dists/stable" "$FPR" "$PUBKEY_ASC"

# reprepro bookkeeping must not be served publicly.
rm -rf "$OUT_DIR/conf" "$OUT_DIR/db"

# The landing page is its own script so it can be tested without gpg or
# reprepro; see scripts/build/build-index-page.sh and tests/build/build-index-page.test.sh.
"$(dirname "$0")/build-index-page.sh" "$OUT_DIR"

if [ -n "$BOOTSTRAP" ]; then
	# Sign the SERVED copy, not the one the caller passed: a mismatch between
	# the two is exactly what an installer must be able to catch, and signing
	# one while serving the other would make that mismatch invisible. --armor
	# with --detach-sign writes the signature only, not the data and the
	# signature together.
	cp "$BOOTSTRAP" "$OUT_DIR/glyndor-archive-keyring.deb"
	gpg --batch --local-user "$FPR" --armor --detach-sign \
		--output "$OUT_DIR/glyndor-archive-keyring.deb.asc" \
		"$OUT_DIR/glyndor-archive-keyring.deb"
	echo "bootstrap keyring package served at $OUT_DIR/glyndor-archive-keyring.deb (signed by $FPR)"
fi

echo "apt repository built at $OUT_DIR (signed by $FPR)"
