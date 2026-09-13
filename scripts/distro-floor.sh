#!/bin/sh
#
# Runs as root inside a fresh Debian or Ubuntu container and asks one question
# about that release: does the served install line for a product end the way
# the README says it should there?
#
#   distro-floor.sh install <product>   the product installs and is on PATH
#   distro-floor.sh refuse  <product>   the install is refused, and the
#                                       refusal names podman, which is the floor
#
# The installer is downloaded to a file and run from it rather than piped, so
# a failed download is a failure here and not an empty script that exits 0.
# POSIX sh throughout: the images ship dash, not bash.
#
# Exit 0 when the release behaves as expected, 1 otherwise. The installer's
# own output is printed either way, so a red run shows what an operator on
# that release would have seen.
set -eu

usage="usage: distro-floor.sh install|refuse <product>"
expect="${1:?$usage}"
product="${2:?$usage}"
base_url="${BASE_URL:-https://apt.glyndor.net}"

fail() {
	echo "distro-floor: $*" >&2
	exit 1
}

case "$expect" in
	install|refuse) ;;
	*) fail "expectation must be install or refuse, got: $expect" ;;
esac

# What the installer itself needs and a fresh image lacks. Quiet on purpose:
# the output that matters is the installer's.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl ca-certificates >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --max-time 60 "$base_url/install/$product" -o "$work/install.sh" \
	|| fail "could not download $base_url/install/$product"

set +e
sh "$work/install.sh" >"$work/log" 2>&1
rc=$?
set -e
cat "$work/log"

case "$expect" in
	install)
		[ "$rc" -eq 0 ] \
			|| fail "the installer exited $rc on a release the README lists as supported"
		command -v "$product" >/dev/null 2>&1 \
			|| fail "the installer exited 0 but $product is not on PATH"
		echo "distro-floor: $product installs here, as the README says"
		;;
	refuse)
		[ "$rc" -ne 0 ] \
			|| fail "the installer succeeded on a release the README lists as unsupported"
		grep -q 'podman (>= 5.0)' "$work/log" \
			|| fail "the installer was refused, but the refusal does not name podman (>= 5.0)"
		echo "distro-floor: $product is refused here and the refusal names podman, as the README says"
		;;
esac
