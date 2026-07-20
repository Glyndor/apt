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
# keyring/version plus the date the packaged inputs last changed, not the
# filename, so the published asset URL is stable).
#
# The version suffix tracks EVERY file this package installs — the key and the
# sources list — not just the key. Tracking only the key meant that editing
# keyring/glyndor.sources changed what clients would install while the version
# stood still, so apt saw the version it already had and never delivered it: a
# configuration change lost in silence, which is the one failure this package
# exists to prevent. Nothing catches that either, because the published archive
# stays perfectly self-consistent while being wrong (#56). keyring/version needs
# no tracking, being the base version itself.
#
# Key rotation (two-phase, automatic to clients): put both the old and the new
# armored key blocks in keyring/glyndor-apt-key.asc during the overlap window —
# `gpg --dearmor` concatenates them so apt trusts both — then drop the old one.
# Any change to a packaged input yields a strictly higher version that
# `apt upgrade` delivers, while an unchanged input set keeps the same version
# (no churn). Requires the script to run inside a git checkout with history
# (CI uses fetch-depth: 0).

set -euo pipefail

OUT_DIR="${1:?usage: build-keyring.sh <output-dir>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBKEY_ASC="$HERE/keyring/glyndor-apt-key.asc"
SOURCES="$HERE/keyring/glyndor.sources"

# Every file this package installs. The version suffix is the date the newest of
# them last changed, so any edit to what clients receive bumps the version that
# reaches them.
PACKAGED_INPUTS=(keyring/glyndor-apt-key.asc keyring/glyndor.sources)

# Base version from keyring/version, suffixed with that date.
BASE_VERSION="$(cat "$HERE/keyring/version")"
PKG_DATE="$(git -C "$HERE" log -1 --format=%cd --date=format:%Y%m%d%H%M%S \
	-- "${PACKAGED_INPUTS[@]}" 2>/dev/null || true)"
# The same commit as a Unix timestamp, used below to make the build
# reproducible. Derived from repository state rather than the clock, so two
# builds of the same checkout are byte-identical.
PKG_EPOCH="$(git -C "$HERE" log -1 --format=%ct \
	-- "${PACKAGED_INPUTS[@]}" 2>/dev/null || true)"
# Fail closed if that date can't be derived. A bare version would not bump when
# the key or the sources list changed, so apt upgrade would silently fail to
# deliver it — the opposite of the guarantee this package exists to provide. The
# build must run inside a full checkout (CI uses fetch-depth: 0).
if [ -z "$PKG_DATE" ] || [ -z "$PKG_EPOCH" ]; then
	echo "::error::no git history for the packaged inputs (${PACKAGED_INPUTS[*]}); cannot derive an upgrade-safe version (run inside a full git checkout)" >&2
	exit 1
fi
# The suffix is +pkg, not +key: it tracks the packaged inputs, and a name that
# says "key" would be a claim the code stopped honouring. Checked with
# `dpkg --compare-versions` before the rename — 1.0.0+pkg<date> sorts strictly
# above the 1.0.0+key<date> already published, so no installed client is
# stranded on a version apt would refuse to upgrade.
VERSION="${BASE_VERSION}+pkg${PKG_DATE}"

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

# Fail closed if dearmor produced no key, and report how many it carries so a
# two-phase rotation (both keys present during the overlap) is visible in logs.
key_count="$(gpg --show-keys --with-colons "$ROOT/usr/share/keyrings/glyndor.gpg" 2>/dev/null \
	| grep -c '^pub:' || true)"
[ "$key_count" -ge 1 ] || { echo "::error::keyring contains no usable key" >&2; exit 1; }
echo "keyring carries $key_count key(s)"

install -m 0644 "$SOURCES" "$ROOT/etc/apt/sources.list.d/glyndor.sources"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: glyndor-archive-keyring
Version: $VERSION
Architecture: all
Maintainer: Glyndor <packages@glyndor.net>
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

# Build reproducibly. Without this the tree's mtimes are the build time, they go
# into the .deb's tar members, and two builds of the same checkout differ in
# both content AND size (measured: 1296 vs 1298 bytes, two seconds apart).
#
# That is not cosmetic here. The version encodes when the packaged inputs last
# changed, so the pool filename stays the same across rebuilds while the bytes
# do not — and the publish syncs pool/ with --size-only. When a rebuild happened
# to land on the same size, the upload was skipped while reprepro had already
# put the NEW hash in the signed index, so the archive served a package its own
# index rejected. Making the build a pure function of the inputs is what earns
# the version's claim.
#
# The epoch comes from the packaged inputs' newest commit, so it is repository
# state and not the clock; dpkg-deb reads SOURCE_DATE_EPOCH, and the touch
# covers the tree, which install(1) stamped with the current time.
export SOURCE_DATE_EPOCH="$PKG_EPOCH"
find "$ROOT" -print0 | xargs -0 touch --no-dereference --date="@$PKG_EPOCH"

dpkg-deb --root-owner-group --build "$ROOT" \
	"$OUT_DIR/glyndor-archive-keyring.deb" >/dev/null

echo "$OUT_DIR/glyndor-archive-keyring.deb"
