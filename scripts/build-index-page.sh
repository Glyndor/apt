#!/usr/bin/env bash
#
# Write the landing page served at the archive root.
#
# Split out of build-repo.sh so it can be tested: the rest of that script needs
# gpg and reprepro, this needs neither — it reads the index reprepro has already
# written and produces HTML. It is also the only part of the archive that
# reaches a browser, and the package names it embeds come from each .deb's
# control field, which publish.yml calls attacker-influenced because whoever can
# publish a product release controls them.
#
# Usage: build-index-page.sh <built-dir>
#   <built-dir>  the directory reprepro wrote (contains dists/, pool/)
set -euo pipefail

OUT_DIR="${1:-}"
[ -n "$OUT_DIR" ] || { echo "usage: build-index-page.sh <built-dir>" >&2; exit 2; }

# The landing page states which architectures the archive serves and how to
# install from it. Both used to be typed out here. The architecture line was a
# FIFTH place the architecture list lives, missing from the four the product
# context tracks, and the only one a user reads. Derive both from the index
# reprepro has just written, the same discipline as the Cloudflare purge list
# (#48) — a hand-written list drifts from what is actually served, silently and
# in both directions.
release="$OUT_DIR/dists/stable/Release"
[ -r "$release" ] \
	|| { echo "no signed Release at $release; nothing to build a page from" >&2; exit 1; }

ARCHES="$(awk '/^Architectures:/ { $1 = ""; sub(/^ +/, ""); print; exit }' \
	"$OUT_DIR/dists/stable/Release")"
[ -n "$ARCHES" ] \
	|| { echo "the built Release declares no architectures" >&2; exit 1; }
# The Architectures value is interpolated into the served HTML on the line
# below — same threat model as the package-name check further down: bytes
# signed by the archive key that reach a browser. Valid architectures are
# space-separated lowercase alphanumeric tokens (amd64, arm64, armhf, all,
# source, …); reject anything else before it can become HTML. Validate each
# token independently so the character class does not have to allow space
# (which breaks bash's case-pattern parser inside `[!...]`).
for arch in $ARCHES; do
	case "$arch" in
		''|*[!a-z0-9.+-]*)
			echo "the built Release's Architectures field contains unexpected characters: $ARCHES" >&2
			exit 1
			;;
	esac
done
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
	| grep -vx 'glyndor-archive-keyring' | LC_ALL=C sort -u)
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
