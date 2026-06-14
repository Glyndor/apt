#!/usr/bin/env bash
#
# Build the signed Glyndor apt repository into a directory ready to publish as a
# static site (GitHub Pages). The repository is rebuilt fresh on every run from
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

DOMAIN="apt.glyndor.net"

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

printf '%s' "$GLYNDOR_APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import 2>/dev/null
FPR="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || { echo "could not determine signing key fingerprint" >&2; exit 1; }

# Fail closed if the committed public key does not match the signing secret.
PUB_FPR="$(gpg --batch --with-colons --show-keys "$PUBKEY_ASC" | awk -F: '/^fpr:/{print $10; exit}')"
if [ "$PUB_FPR" != "$FPR" ]; then
	echo "::error::committed public key ($PUB_FPR) does not match signing key ($FPR)" >&2
	exit 1
fi

CONF="$OUT_DIR/conf"
mkdir -p "$CONF"
cat > "$CONF/distributions" <<EOF
Origin: Glyndor
Label: Glyndor
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Glyndor apt repository
SignWith: $FPR
EOF

reprepro -b "$OUT_DIR" includedeb stable "${DEBS[@]}"

# reprepro bookkeeping must not be served publicly.
rm -rf "$OUT_DIR/conf" "$OUT_DIR/db"

touch "$OUT_DIR/.nojekyll"
printf '%s\n' "$DOMAIN" > "$OUT_DIR/CNAME"
cp "$PUBKEY_ASC" "$OUT_DIR/glyndor-apt-key.asc"

cat > "$OUT_DIR/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Glyndor apt repository</title>
<h1>Glyndor apt repository</h1>
<p>Set up on Debian/Ubuntu (amd64):</p>
<pre>curl -fsSLO https://apt.glyndor.net/glyndor-archive-keyring.deb
sudo dpkg -i glyndor-archive-keyring.deb
sudo apt update</pre>
<p>Then install any package, e.g. <code>sudo apt install podup</code>.</p>
<p>Source: <a href="https://github.com/Glyndor/apt">github.com/Glyndor/apt</a></p>
EOF

echo "apt repository built at $OUT_DIR (signed by $FPR)"
