#!/usr/bin/env bash
#
# Write the landing page served at the archive root.
#
# Split out of build-repo.sh so it can be tested: the rest of that script needs
# gpg and reprepro, this needs neither: it reads the index reprepro has already
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
# (#48), because a hand-written list drifts from what is actually served, silently and
# in both directions.
release="$OUT_DIR/dists/stable/Release"
[ -r "$release" ] \
	|| { echo "no signed Release at $release; nothing to build a page from" >&2; exit 1; }

ARCHES="$(awk '/^Architectures:/ { $1 = ""; sub(/^ +/, ""); print; exit }' \
	"$OUT_DIR/dists/stable/Release")"
[ -n "$ARCHES" ] \
	|| { echo "the built Release declares no architectures" >&2; exit 1; }
# The Architectures value is interpolated into the served HTML on the line
# below, same threat model as the package-name check further down: bytes
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

# One <li> per installable package, offering the bootstrap installer rather than
# `apt install`. The keyring carries the allowlist entry, so an `apt install`
# gets Glyndor packages onto the unattended-upgrades allowlist, but an allowlist
# does nothing where unattended upgrades are not switched on, and the switch
# (`20auto-upgrades`) is written by the installer alone. A page that stopped at
# `apt install` left a machine that looked complete and quietly stopped taking
# security fixes. README.md says the same thing; the two are read by the same
# person and must not disagree.
#
# The installer path is /install/<product>, generated from PRODUCTS, while this
# list comes from the built index. They agree because a product's package
# carries the product's name, which is what build-installers.sh is given.
#
# The keyring is excluded: it is the bootstrap the manual block below installs
# with dpkg, not something to offer an installer for.
#
# Package names come from each .deb's control field, so they are
# attacker-influenced in principle even though verify-debs.sh binds every one to
# the product that released it. A Debian package name cannot contain an HTML
# metacharacter, but check the charset rather than trust that, because this string is
# served to browsers.
# What a reader has to be told, and the reason this page was wrong.
#
# The page promised "Debian/Ubuntu" with no qualifier, and that is where someone
# meets the claim. It is not true of most of Debian and Ubuntu: a package can
# declare a dependency its release does not carry, and then adding the archive
# succeeds while `apt install` fails. Measured on 2026-09-07 with podup 5.9.1,
# which declares `podman (>= 5.0)`: Ubuntu 24.04 LTS ships 4.9.3 and has no
# backport, so the archive adds cleanly there and the install cannot complete.
#
# Only the REQUIREMENT is stated here, never the releases that satisfy it. The
# requirement is read out of the signed index and is regenerated every publish,
# so it follows a product that changes its floor. A list of distributions would
# be a claim about the world that nothing in this repository can falsify, and it
# would go stale the next time a release moves. Where a release does satisfy it
# belongs in the product's own documentation, which is maintained against it.
#
# A dependency naming a package this archive itself serves is resolved by apt
# from here, so it is not something the reader has to supply. Deriving that set
# from the index rather than listing our own names keeps it true as the roster
# grows.
# No sort and no dedup: this is only ever asked "is this name in here", by
# `grep -qxF`, and duplicates across the per-architecture indices answer that
# identically. The package LIST further down does sort, under a pinned
# collation, because there the order and the dedup are what reach the page.
OWN_PACKAGES="$(awk '/^Package:/ { print $2 }' \
	"$OUT_DIR"/dists/stable/main/binary-*/Packages)"

# depends_of <package>: the raw Depends line, or nothing.
depends_of() {
	awk -v want="$1" '
		/^Package:/ { name = $2 }
		/^Depends:/ { if (name == want) { $1 = ""; sub(/^ +/, ""); print; exit } }
	' "$OUT_DIR"/dists/stable/main/binary-*/Packages
}

# html_escape <string>
#
# Two traps, both of which produced wrong output before they were escaped.
#
# The ampersand goes first, or the entities the later rules insert get their own
# ampersands rewritten.
#
# And every `&` in the REPLACEMENT is backslash-escaped, because bash expands a
# bare one there to the text that just matched, the way sed does. Written
# unescaped, `${s//>/&gt;}` turned `podman (>= 5.0)` into `podman (>gt;= 5.0)`:
# the entity lost its ampersand and the `>` it was there to remove survived.
# Rendering the page is what showed it; the function looks right in the diff.
html_escape() {
	local s="$1"
	s="${s//&/\&amp;}"
	s="${s//</\&lt;}"
	s="${s//>/\&gt;}"
	printf '%s' "$s"
}

# external_requirements <package>: the dependencies the reader's distribution
# has to provide, comma-separated and HTML-escaped. Same threat model as the
# package names below: these come from a .deb's control field and are served to
# a browser, so the charset is checked rather than trusted. A version relation
# carries `>` and `<<`, which is exactly why escaping is not optional here.
external_requirements() {
	local deps dep base out=""
	deps="$(depends_of "$1")"
	[ -n "$deps" ] || return 0
	local IFS=','
	for dep in $deps; do
		dep="${dep#"${dep%%[![:space:]]*}"}"
		dep="${dep%"${dep##*[![:space:]]}"}"
		[ -n "$dep" ] || continue
		base="${dep%%[[:space:]|]*}"
		if printf '%s\n' "$OWN_PACKAGES" | grep -qxF "$base"; then
			continue
		fi
		case "$dep" in
			*[!a-zA-Z0-9+.:~\(\)\<\>=\ \|-]*)
				echo "skipping unexpected dependency of $1: $dep" >&2
				continue
				;;
		esac
		out="$out, <code>$(html_escape "$dep")</code>"
	done
	printf '%s' "${out#, }"
}

PACKAGE_ITEMS=""
while IFS= read -r pkg; do
	case "$pkg" in
		''|*[!a-z0-9+.-]*)
			echo "skipping unexpected package name in the built index: $pkg" >&2
			continue
			;;
	esac
	req="$(external_requirements "$pkg")"
	PACKAGE_ITEMS="$PACKAGE_ITEMS<li><code>curl -fsSL https://apt.glyndor.net/install/$pkg | sudo sh</code>${req:+ <span>needs $req</span>}</li>"
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
<p>Debian/Ubuntu ($ARCH_LIST). One line per package:</p>
<ul>$PACKAGE_ITEMS</ul>
<p>Adding this archive works wherever apt does. Installing a package also takes
whatever that package requires, shown beside it above, and that comes from your
distribution rather than from here: a release that does not carry it can add the
archive and still fail to install. Each product's own documentation is where to
look for which releases carry what it asks for.</p>
<p>The script adds this archive, checks the archive key's fingerprint before
anything runs as root, installs the package, and switches on automatic security
upgrades.</p>
<p>To check the archive key by hand before trusting it, or to verify a copy
already installed, see
<a href="https://github.com/Glyndor/apt#verify-the-signing-key">the repository
README</a>. The fingerprint is published there and not here on purpose: a page
served from this archive cannot vouch for its own key.</p>
<p>Source: <a href="https://github.com/Glyndor/apt">github.com/Glyndor/apt</a></p>
EOF
