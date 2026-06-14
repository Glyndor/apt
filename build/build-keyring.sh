#!/usr/bin/env bash
#
# Build the glyndor-archive-keyring .deb.
#
# Installs the apt repository signing key and source list so that, once it is
# installed, `apt install <product>` works for any Glyndor package and key
# renewals arrive through the normal `apt upgrade` flow (apt owns the key file).
#
# Usage:
#   build-keyring.sh <output-dir>
#
# Produces: <output-dir>/glyndor-archive-keyring.deb (version comes from
# keyring/VERSION, not the filename, so the published asset URL is stable).

set -euo pipefail

OUT_DIR="${1:?usage: build-keyring.sh <output-dir>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBKEY_ASC="$HERE/keyring/glyndor-apt-key.asc"
SOURCES="$HERE/keyring/glyndor.sources"
VERSION="$(cat "$HERE/keyring/VERSION")"

[ -f "$PUBKEY_ASC" ] || { echo "missing public key: $PUBKEY_ASC" >&2; exit 1; }
[ -f "$SOURCES" ]    || { echo "missing sources file: $SOURCES" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
chmod 0755 "$ROOT"

install -d -m 0755 "$ROOT/DEBIAN"
install -d -m 0755 "$ROOT/usr/share/keyrings"
install -d -m 0755 "$ROOT/etc/apt/sources.list.d"

gpg --dearmor < "$PUBKEY_ASC" > "$ROOT/usr/share/keyrings/glyndor.gpg"
chmod 0644 "$ROOT/usr/share/keyrings/glyndor.gpg"
install -m 0644 "$SOURCES" "$ROOT/etc/apt/sources.list.d/glyndor.sources"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: glyndor-archive-keyring
Version: $VERSION
Architecture: all
Maintainer: Glyndor <75870284+Jaro-c@users.noreply.github.com>
Section: utils
Priority: optional
Homepage: https://github.com/Glyndor/apt
Description: GPG key and apt source for the Glyndor repository
 Installs the signing key and source list for the Glyndor apt repository at
 https://apt.glyndor.net so Glyndor packages can be installed and kept up to
 date with apt. Key renewals are delivered through apt upgrade.
EOF

cat > "$ROOT/DEBIAN/conffiles" <<'EOF'
/etc/apt/sources.list.d/glyndor.sources
EOF

dpkg-deb --root-owner-group --build "$ROOT" \
	"$OUT_DIR/glyndor-archive-keyring.deb" >/dev/null

echo "$OUT_DIR/glyndor-archive-keyring.deb"
