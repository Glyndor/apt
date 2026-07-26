#!/usr/bin/env bash
#
# Build the signed Glyndor apt repository into a directory ready to publish to
# Cloudflare R2 (apt.glyndor.net). The repository is rebuilt fresh on every run from
# the current release of each product, so it always carries exactly the latest
# version of every package — Glyndor ships no old-version support.
#
# Requires: reprepro, gpg.
# Reads the armored private signing key from $GLYNDOR_APT_GPG_PRIVATE_KEY.
#
# Usage:
#   GLYNDOR_APT_GPG_PRIVATE_KEY="$(cat priv.asc)" \
#     build-repo.sh <output-dir> <deb> [<deb> ...]

set -euo pipefail

OUT_DIR="${1:?usage: build-repo.sh <output-dir> <deb> [<deb> ...]}"
shift
[ "$#" -ge 1 ] || { echo "no .deb files given" >&2; exit 1; }

: "${GLYNDOR_APT_GPG_PRIVATE_KEY:?GLYNDOR_APT_GPG_PRIVATE_KEY is not set}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
cleanup() { gpgconf --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"; }
trap cleanup EXIT

# Import the signing key. Don't swallow import errors — if the secret is
# malformed the failure must be diagnosable, not silent.
printf '%s' "$GLYNDOR_APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import

# The key now lives in the ephemeral GNUPGHOME above; nothing past this point
# needs it in the environment, and no child process (or a stray debug trace)
# should be able to read the private key out of this shell's env after import.
unset GLYNDOR_APT_GPG_PRIVATE_KEY

# Require exactly one secret key. If the secret ever carried more than one (e.g.
# old + new pasted in during a rotation), the first-fingerprint pick below would
# sign with whichever imported first, not necessarily the intended active key.
# `grep -c` exits 1 on zero matches, which pipefail would turn into a silent
# death inside the substitution — guard it so the count (0) reaches the
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
SignWith: $FPR
EOF

reprepro -b "$OUT_DIR" includedeb stable "${DEBS[@]}"

# reprepro bookkeeping must not be served publicly.
rm -rf "$OUT_DIR/conf" "$OUT_DIR/db"

# The landing page states which architectures the archive serves and how to
# install from it. Both used to be typed out here. The architecture line was a
# FIFTH place the architecture list lives, missing from the four the product
# context tracks, and the only one a user reads. Derive both from the index
# reprepro has just written, the same discipline as the Cloudflare purge list
# (#48) — a hand-written list drifts from what is actually served, silently and
# in both directions.
ARCHES="$(awk '/^Architectures:/ { $1 = ""; sub(/^ +/, ""); print; exit }' \
	"$OUT_DIR/dists/stable/Release")"
[ -n "$ARCHES" ] \
	|| { echo "the built Release declares no architectures" >&2; exit 1; }
ARCH_LIST="${ARCHES// /, }"

# One <li> per installable package. The keyring is excluded: it is the bootstrap
# the block above already installs with dpkg, not something to apt-install.
#
# Package names come from each .deb's control field, so they are
# attacker-influenced in principle even though verify-debs.sh binds every one to
# the product that released it. A Debian package name cannot contain an HTML
# metacharacter, but check the charset rather than trust that — this string is
# served to browsers.
PACKAGE_ITEMS=""
while IFS= read -r pkg; do
	case "$pkg" in
		''|*[!a-z0-9+.-]*)
			echo "skipping unexpected package name in the built index: $pkg" >&2
			continue
			;;
	esac
	PACKAGE_ITEMS="$PACKAGE_ITEMS<li><code>sudo apt install $pkg</code></li>"
done <<EOF_PKGS
$(awk '/^Package:/ { print $2 }' "$OUT_DIR"/dists/stable/main/binary-*/Packages \
	| grep -vx 'glyndor-archive-keyring' | sort -u)
EOF_PKGS
[ -n "$PACKAGE_ITEMS" ] \
	|| { echo "the built indices declare no installable packages" >&2; exit 1; }

cat > "$OUT_DIR/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Glyndor apt repository</title>
<h1>Glyndor apt repository</h1>
<p>Set up on Debian/Ubuntu ($ARCH_LIST):</p>
<pre>curl -fsSLO https://apt.glyndor.net/glyndor-archive-keyring.deb
sudo dpkg -i glyndor-archive-keyring.deb
sudo apt update</pre>
<p>Then install any of the packages this archive serves:</p>
<ul>$PACKAGE_ITEMS</ul>
<p>Verify the installed signing key against the fingerprint published in the
<a href="https://github.com/Glyndor/apt#verify-the-signing-key">repository README</a>
(an independent channel): <code>gpg --show-keys /usr/share/keyrings/glyndor.gpg</code></p>
<p>Source: <a href="https://github.com/Glyndor/apt">github.com/Glyndor/apt</a></p>
EOF

echo "apt repository built at $OUT_DIR (signed by $FPR)"
