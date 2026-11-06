#!/usr/bin/env bash
#
# Refuse a release that is older than the one the archive already serves.
#
# WHY THIS CHECK EXISTS
#
#   The publish resolves each product's "latest" release and rebuilds the
#   whole archive from it. "Latest" is a pointer GitHub keeps, not a version:
#   an older release that is re-marked as the latest one is still "the latest
#   release", and its .deb is still validly signed by the release key. Every
#   admission check in this repository therefore passes it, and the archive
#   moves backwards: `apt upgrade` hands every client the older package as if
#   it were the newest one (issue #360).
#
#   The other two channels refuse it: the homebrew tap compares the candidate
#   with the version its formula already serves and the scoop bucket compares
#   it with the version its manifest already serves, both with SemVer
#   precedence. This is the apt channel's copy of that decision, with the
#   served version read out of the archive's own signed index.
#
# WHAT IS COMPARED
#
#   The version the release tag names, against the version the archive serves
#   today. Equal or greater passes; lower fails, with the reason named. A
#   product the archive does not serve yet passes: a first publication.
#
#   The served version comes out of the signed index, not out of a plain
#   download. The served InRelease is verified with the archive public key
#   (the key verify-published.sh trusts and the one every client holds), the
#   per-architecture Packages files it declares are fetched and checked against
#   the size and SHA256 it declares, and the product's Version is read out of
#   those bytes. The signature is what makes the comparison mean something: a
#   network position answering with an older index would hide a rollback
#   instead of stopping it.
#
# FAILS CLOSED
#
#   An index that cannot be read, a signature that does not verify, a Packages
#   file that does not match what was signed, and a version that cannot be
#   parsed are all errors, each with the reason named. A check that cannot
#   establish what the archive serves cannot certify the candidate, and this
#   archive is rebuilt from scratch and synced with --delete.
#
# Usage:
#   check-release-order.sh <product> <tag> <base-url> [<pubkey-asc>]
#
# Requires: curl, gpg, gpgv, python3, sha256sum.

set -euo pipefail

PRODUCT="${1:?usage: check-release-order.sh <product> <tag> <base-url> [<pubkey-asc>]}"
TAG="${2:?usage: check-release-order.sh <product> <tag> <base-url> [<pubkey-asc>]}"
BASE_URL="${3:?usage: check-release-order.sh <product> <tag> <base-url> [<pubkey-asc>]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBKEY_ASC="${4:-$HERE/keyring/glyndor-apt-key.asc}"

# The distribution this archive publishes and the path its index lives under:
# the same path verify-published.sh reads and build-repo.sh signs.
DIST_PATH="dists/stable"

# Bounds on what this script reads off the network: signed is not a size limit.
MAX_INRELEASE_BYTES=$((1024 * 1024))
MAX_INDEX_BYTES=$((8 * 1024 * 1024))

# A trailing slash would make every URL below carry a double one.
BASE_URL="${BASE_URL%/}"

WORK="$(mktemp -d)"
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() {
	gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	rm -rf "$WORK" "$GNUPGHOME"
}
trap cleanup EXIT

[ -f "$PUBKEY_ASC" ] || { echo "::error::archive public key $PUBKEY_ASC not found" >&2; exit 1; }
gpg --batch --quiet --import "$PUBKEY_ASC" \
	|| { echo "::error::could not import the archive public key from $PUBKEY_ASC" >&2; exit 1; }

# fetch <url> <destination> <max-bytes>
# One bounded read. --max-time bounds an attempt and --retry-max-time bounds
# the sequence, so a peer that never answers cannot hold the publish.
fetch() {
	curl -fsS --retry 2 --retry-all-errors --retry-delay 2 \
		--max-time 20 --retry-max-time 40 \
		--max-filesize "$3" "$1" -o "$2"
}

sha256_of() { # $1=file
	sha256sum "$1" | cut -d' ' -f1
}

# release_order <product> <candidate-version> <verified-Packages-file>...
#
# Prints one verdict and nothing else: "not-served" when the archive does not
# serve the product yet, "ok <served>" when the candidate is not older than
# what is served, "older <served>" when it is.
#
# The comparison is SemVer precedence: numeric major/minor/patch, a
# pre-release below the release it precedes, numeric pre-release identifiers
# below text ones, build metadata ignored. It is the rule the tap and the
# bucket apply to the same releases, so the three channels refuse the same
# ones; their unit is release_order in scripts/release/render-formulae.sh.
release_order() { # $1=product $2=candidate version $3...=verified Packages files
	python3 -I - "$@" <<'PY'
import re
import sys

product, candidate, paths = sys.argv[1], sys.argv[2], sys.argv[3:]

SEMVER = re.compile(
	r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
	r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
	r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
EPOCH = re.compile(r"^[0-9]+:")
REVISION = re.compile(r"^[0-9][0-9A-Za-z.+~]*$")


def precedence(version):
	# The tuple the comparison sorts on: a pre-release below its release.
	match = SEMVER.fullmatch(version)
	if not match:
		raise ValueError("it is not a valid SemVer version")
	major, minor, patch, pre = match.groups()
	identifiers = [] if pre is None else pre.split(".")
	if any(item.isdigit() and len(item) > 1 and item[0] == "0" for item in identifiers):
		raise ValueError("it has an invalid numeric pre-release identifier")
	return (int(major), int(minor), int(patch), pre is None,
		tuple((0, int(item)) if item.isdigit() else (1, item) for item in identifiers))


def upstream(version):
	# The upstream part of a Debian version: no epoch, no packaging revision.
	# The .deb was built from a release tag, so the epoch and the revision
	# belong to the package: the served 5.16.0-1 is the release 5.16.0.
	if EPOCH.match(version):
		version = version.split(":", 1)[1]
	head, dash, revision = version.rpartition("-")
	if dash and REVISION.match(revision):
		version = head
	return version


def versions_of(text):
	# The Version of every stanza that declares this product. A stanza opens
	# at its `Package:` line, not at a blank line: a description may hold one.
	found = []
	fields = {}
	for line in text.splitlines():
		if line.startswith("Package:"):
			if fields.get("Package") == product and "Version" in fields:
				found.append(fields["Version"])
			fields = {}
		if not line or line[0] in " \t":
			continue
		name, sep, value = line.partition(":")
		if sep:
			fields[name.strip()] = value.strip()
	if fields.get("Package") == product and "Version" in fields:
		found.append(fields["Version"])
	return found


try:
	new = precedence(candidate)
except ValueError as error:
	sys.exit(f"the release version {candidate!r} cannot be compared: {error}")

served = []
for path in paths:
	with open(path, encoding="utf-8", errors="replace") as handle:
		served.extend(versions_of(handle.read()))

if not served:
	print("not-served")
	sys.exit(0)

orders = []
for version in served:
	try:
		orders.append((precedence(upstream(version)), version))
	except ValueError as error:
		sys.exit(f"the served version {version!r} of {product} cannot be compared: {error}")

# The highest version the archive serves is the baseline: comparing against
# the lower one would let a publish roll the other architecture back.
highest = max(orders, key=lambda order: order[0])
if new < highest[0]:
	print(f"older {highest[1]}")
else:
	print(f"ok {highest[1]}")
PY
}

echo "checking whether $TAG is older than the $PRODUCT version the archive serves"

# --- the signed index --------------------------------------------------------

if ! fetch "$BASE_URL/$DIST_PATH/InRelease" "$WORK/InRelease" "$MAX_INRELEASE_BYTES"; then
	echo "::error::could not fetch the served index $BASE_URL/$DIST_PATH/InRelease; the version the archive serves cannot be established" >&2
	exit 1
fi
# gpgv, not gpg --decrypt: the latter exits 0 over any OpenPGP packet, so a
# document carrying no signature would pass it. --output writes the verified
# body, so everything parsed below is what the archive key actually signed.
if ! gpgv --keyring "$GNUPGHOME/pubring.kbx" --quiet \
	--output "$WORK/InRelease.body" "$WORK/InRelease" 2>"$WORK/gpgv.err"; then
	echo "::error::the served index at $BASE_URL/$DIST_PATH/InRelease does not verify against the archive public key; the version the archive serves cannot be established" >&2
	sed 's/^/  /' "$WORK/gpgv.err" >&2
	exit 1
fi

# The per-architecture Packages files the signed index declares, with the size
# and the SHA256 it declares for each. Only the plain ones: reprepro writes
# the uncompressed index beside the compressed one.
if ! python3 -I - "$WORK/InRelease.body" >"$WORK/declared" <<'PY'
import re
import sys

body = open(sys.argv[1], encoding="utf-8", errors="replace").read()
section = re.search(
	r"(?m)^SHA256:[ \t]*\n((?:[ \t]+[0-9a-f]{64}[ \t]+\d+[ \t]+\S+[ \t]*\n)*)", body
)
if not section:
	sys.exit("the served index declares no SHA256 section")
indexes = []
for line in section.group(1).splitlines():
	digest, size, name = line.split()
	if re.fullmatch(r"main/binary-[^/]+/Packages", name):
		indexes.append((digest, int(size), name))
if not indexes:
	sys.exit("the served index declares no per-architecture Packages file")
for digest, size, name in indexes:
	print(digest, size, name)
PY
then
	echo "::error::the served index does not declare a readable per-architecture Packages file" >&2
	exit 1
fi

# --- the index files it declares --------------------------------------------

packages=()
while read -r digest size name; do
	[ -n "$name" ] || continue
	url="$BASE_URL/$DIST_PATH/$name"
	dest="$WORK/${name//\//_}"
	if ! fetch "$url" "$dest" "$MAX_INDEX_BYTES"; then
		echo "::error::could not fetch the served index file $url" >&2
		exit 1
	fi
	got_size="$(stat -c%s "$dest")"
	if [ "$got_size" != "$size" ]; then
		echo "::error::the served $name is $got_size bytes; the signed index declares $size" >&2
		exit 1
	fi
	if [ "$(sha256_of "$dest")" != "$digest" ]; then
		echo "::error::the served $name does not match the SHA256 the signed index declares for it" >&2
		exit 1
	fi
	packages+=("$dest")
done <"$WORK/declared"

[ "${#packages[@]}" -ge 1 ] \
	|| { echo "::error::the signed index declares no per-architecture Packages file" >&2; exit 1; }

# --- the comparison ----------------------------------------------------------

# The tag's leading `v` is not part of the version, the same way
# verify-debs.sh reads it out of the tag it pinned.
candidate="${TAG#v}"

if ! verdict="$(release_order "$PRODUCT" "$candidate" "${packages[@]}")"; then
	echo "::error::could not compare $PRODUCT $candidate against the version the archive serves" >&2
	exit 1
fi

case "$verdict" in
	not-served)
		echo "$PRODUCT is not served yet; $TAG is its first publication"
		;;
	ok\ *)
		echo "$PRODUCT is served as ${verdict#ok }; $TAG is not older than that"
		;;
	older\ *)
		echo "::error::refusing to publish $PRODUCT $TAG: the archive already serves ${verdict#older }, which is newer" >&2
		exit 1
		;;
	*)
		echo "::error::the release-order check returned an unexpected verdict '$verdict'" >&2
		exit 1
		;;
esac
