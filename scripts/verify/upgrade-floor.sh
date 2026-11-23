#!/bin/sh
#
# Runs as root inside a fresh Debian or Ubuntu container and asks one question about the
# archive: does a machine that has the version of a product before the served one end up on
# the served one, with the product still answering, when it runs the upgrade apt offers?
#
#   upgrade-floor.sh <product> [previous.deb]
#
# 1. The published installer puts the served version in place, which is also what sets up
#    the archive's source and key on the machine.
# 2. The product is purged and the version before it is installed. That version comes from
#    the archive when the archive still indexes a lower one. It does not today: the archive
#    keeps the latest version only, so the script is given the .deb of the release before
#    (previous-release.sh fetches it) and says so. With neither, nothing can be tried and the
#    script exits 3, which is not a pass.
# 3. `apt-get install --only-upgrade <product>` is run, which is what the upgrade timer and
#    an operator's `apt upgrade` do, and the machine is held to: the served version is now
#    installed and is newer than the one before, the product starts, dpkg has nothing left
#    half configured, and the files of the package are the ones it shipped.
# The configuration files the package owns are listed with their checksums before and after,
# so a revision that moves or rewrites one shows in the log of the run.
#
# POSIX sh throughout: the images ship dash. Exit 0 when the upgrade holds, 1 when it does
# not, 3 when it cannot be tried.
set -eu

usage="usage: upgrade-floor.sh <product> [previous.deb]"
product="${1:?$usage}"
prev_deb="${2:-}"
base_url="${BASE_URL:-https://apt.glyndor.net}"

fail() {
	echo "upgrade-floor: $*" >&2
	exit 1
}

installed() { dpkg-query -W -f='${Version}' "$product" 2>/dev/null || true; }

conffiles() { # the configuration files the package owns, with a checksum of each
	dpkg-query -W -f='${Conffiles}\n' "$product" 2>/dev/null | awk 'NF { print $1 }' | LC_ALL=C sort | while read -r f; do
		if [ -f "$f" ]; then md5sum "$f"; else echo "missing  $f"; fi
	done
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl ca-certificates >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --max-time 60 "$base_url/install/$product" -o "$work/install.sh" \
	|| fail "could not download $base_url/install/$product"
sh "$work/install.sh" >"$work/install.log" 2>&1 || { cat "$work/install.log"; fail "the published installer failed, so there is nothing to upgrade from"; }

served="$(installed)"
[ -n "$served" ] || fail "the installer exited 0 but $product is not installed"
echo "upgrade-floor: the installer put $product $served in place"

previous=""
source_of=""
# Only what this archive indexes counts: the release's own repositories carry packages of the same name.
host="${base_url#*://}"
for v in $(apt-cache madison "$product" | awk -F'|' -v h="$host" 'index($3, h) { gsub(/ /, "", $2); print $2 }'); do
	if dpkg --compare-versions "$v" lt "$served"; then previous="$v"; source_of="the archive"; break; fi
done
if [ -n "$previous" ]; then
	echo "upgrade-floor: the archive still indexes $product $previous, which is below $served"
elif [ -n "$prev_deb" ]; then
	[ -f "$prev_deb" ] || fail "the previous package $prev_deb does not exist"
	[ "$(dpkg-deb -f "$prev_deb" Package)" = "$product" ] || fail "$prev_deb is not a package of $product"
	previous="$(dpkg-deb -f "$prev_deb" Version)"
	dpkg --compare-versions "$previous" lt "$served" || fail "the previous package is $previous, which is not below the served $served"
	source_of="the release before"
	echo "upgrade-floor: the archive keeps no version of $product below $served, as it serves the latest only; the version before it, $previous, is the one of the previous release"
else
	echo "upgrade-floor: NOT VERIFIED: the archive keeps no version of $product below $served and no earlier package was given, so an upgrade to $served cannot be tried here" >&2
	exit 3
fi

apt-get purge -y -qq "$product" >/dev/null || fail "could not remove $product to put the previous version in its place"
if [ "$source_of" = "the archive" ]; then
	apt-get install -y -qq --allow-downgrades "$product=$previous" >/dev/null || fail "could not install $product $previous from the archive"
else
	case "$prev_deb" in /*) ;; *) prev_deb="$PWD/$prev_deb" ;; esac
	apt-get install -y -qq --allow-downgrades "$prev_deb" >/dev/null || fail "could not install $prev_deb"
fi
[ "$(installed)" = "$previous" ] || fail "$product is $(installed), not the $previous that was installed"
"$product" --version >/dev/null 2>&1 || fail "$product $previous does not start before the upgrade, so the upgrade would prove nothing"
echo "upgrade-floor: $product $previous installed from $source_of and starts"
conffiles >"$work/conf.before"

apt-get update -qq >/dev/null
candidate="$(apt-cache policy "$product" | awk '/Candidate:/ { print $2 }')"
[ "$candidate" = "$served" ] || fail "apt offers $product $candidate, not the served $served the installer put in place"
apt-get install -y -qq --only-upgrade "$product" >"$work/upgrade.log" 2>&1 || { cat "$work/upgrade.log"; fail "apt-get install --only-upgrade $product failed"; }

now="$(installed)"
[ "$now" = "$served" ] || fail "after the upgrade $product is $now, not the served $served"
"$product" --version >/dev/null 2>&1 || fail "$product $now does not start after the upgrade"
[ -z "$(dpkg --audit)" ] || { dpkg --audit; fail "dpkg reports packages that are not fully configured after the upgrade"; }
# The container images drop the manual pages, the docs and the translations from every package (dpkg
# path-exclude), so dpkg reports them as missing; that is the image and not the package.
verify="$(dpkg -V "$product" 2>&1 | grep -vE ' /usr/share/(man|doc|info|locale|lintian)/' || true)"
[ -z "$verify" ] || { echo "$verify"; fail "files of $product differ from what the package shipped after the upgrade"; }
conffiles >"$work/conf.after"
if [ ! -s "$work/conf.before" ] && [ ! -s "$work/conf.after" ]; then
	echo "upgrade-floor: $product owns no configuration file under /etc, so there is none to carry over"
elif cmp -s "$work/conf.before" "$work/conf.after"; then
	echo "upgrade-floor: the configuration files of $product are the same before and after"
else
	echo "upgrade-floor: the configuration files of $product changed in the upgrade:"
	diff "$work/conf.before" "$work/conf.after" | sed 's/^/    /' || true
fi
echo "upgrade-floor: $product went from $previous ($source_of) to $now and starts, as the README says"
