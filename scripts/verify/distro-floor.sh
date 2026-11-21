#!/bin/sh
#
# Runs as root inside a fresh Debian or Ubuntu container and asks one question
# about that release: does the served install line for a product end the way
# the README says it should there?
#
#   distro-floor.sh install <product>   the product installs and is on PATH
#   distro-floor.sh refuse  <product>   the install is refused, and the refusal
#                                       names the floor the README states: the
#                                       libc6 version the podman package of this
#                                       archive needs, `libc6 (>= 2.39)`
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
# The glibc the archive's podman needs, which is the floor the README states. A refusal
# that names another number, or another package, is not the one the table promises.
floor_libc="2.39"

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
		"$product" --version >/dev/null 2>&1 \
			|| fail "$product is on PATH but does not start; the installer did not notice"
		echo "distro-floor: $product installs here, as the README says"
		;;
	refuse)
		[ "$rc" -ne 0 ] \
			|| fail "the installer succeeded on a release the README lists as unsupported"
		# The archive serves its own podman, built for glibc 2.39 or newer: the package
		# declares libc6 (>= 2.39), so apt refuses it where glibc is older rather than
		# installing a binary that does not start. That is the refusal the README
		# documents, so it is the one asked for: a refusal that names podman (>= 5.0)
		# is the release shipping an old podman, which the archive no longer depends on.
		grep -qF "libc6 (>= $floor_libc)" "$work/log" \
			|| fail "the installer was refused, but the refusal does not name the floor: libc6 (>= $floor_libc)"
		echo "distro-floor: $product is refused here and the refusal names the floor, as the README says"
		;;
esac
