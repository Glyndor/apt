#!/usr/bin/env bash
#
# Verify every product .deb in a directory against its detached Ed25519 .sig
# using the shared Glyndor release public key. Fails closed: a missing or
# invalid signature aborts the publish, so the archive never re-signs (and
# vouches for, with its own GPG key) a binary it did not verify.
#
# Each product's release workflow signs its .deb with the org release signing
# key (the same key install.sh trusts) and attaches a <deb>.sig asset. This is
# a separate trust anchor from the apt archive GPG key: the release key proves
# the upstream binary is authentic; the archive key proves the repository
# metadata is authentic.
#
# The key file carries one base64-encoded Ed25519 public key per line. More than
# one key may be present so a two-phase release-key rotation can trust the old
# and the new key at once during the overlap: a .deb is admitted if any listed
# key verifies it. Blank lines and lines starting with '#' are ignored.
#
# Requires: python3 with the `cryptography` module, and dpkg-deb.
#
# Usage:
#   verify-debs.sh <debs-dir> [<pubkey-b64-file>] [<expected_package>] [<expected_tag>]
#
# When expected_tag is given, every .deb must declare a Version whose upstream
# part equals that tag without its leading `v`. The signature covers the bytes
# and not the tag they were attached to, so this is what stops a still-valid
# .deb from an older release being re-attached to a new one.
#
# When expected_package is given, every .deb in debs-dir must also declare it
# as the control Package field AND carry it as the filename prefix
# ("<expected_package>_..."). The release key is shared by every Glyndor
# product, so a valid signature alone does not prove a .deb is the product it
# was downloaded from, since a compromised release could otherwise ship an asset
# whose control Package (and/or filename) claims to be a different product.

set -euo pipefail

DEBS_DIR="${1:?usage: verify-debs.sh <debs-dir> [<pubkey-b64-file>] [<expected_package>] [<expected_tag>]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${2:-$HERE/keyring/glyndor-release-ed25519.b64}"
EXPECTED_PACKAGE="${3:-}"
# The release tag the directory was downloaded from, e.g. v5.9.2. Optional so
# the suite can exercise the other gates on their own, and passed by publish.yml
# from the tag it already pinned per product.
EXPECTED_TAG="${4:-}"

[ -f "$KEY_FILE" ] || { echo "::error::release public key $KEY_FILE not found" >&2; exit 1; }

# One base64 key per non-empty, non-comment line. Strip whitespace per line so
# the multi-key form (one key per line) is not flattened into a single blob.
KEYS=()
while IFS= read -r line || [ -n "$line" ]; do
	line="$(printf '%s' "$line" | tr -d '[:space:]')"
	case "$line" in '' | '#'*) continue ;; esac
	KEYS+=("$line")
done < "$KEY_FILE"
[ "${#KEYS[@]}" -ge 1 ] || { echo "::error::release public key $KEY_FILE has no keys" >&2; exit 1; }

shopt -s nullglob
debs=("$DEBS_DIR"/*.deb)
[ "${#debs[@]}" -ge 1 ] || { echo "::error::no .deb files to verify in $DEBS_DIR" >&2; exit 1; }

count=0
for deb in "${debs[@]}"; do
	# Every .deb here is an untrusted downloaded release asset and must be
	# verified with no exceptions: keying a skip on the filename would let a
	# product publish an asset under a trusted name to bypass the check. The
	# locally-built keyring package is produced in a later step (build-keyring),
	# after this runs, and is signed by the archive key, not the release key.

	# Reject the reserved keyring name on the *filename* as well as the control
	# field below: a product could ship an asset literally named
	# glyndor-archive-keyring_*.deb and, if this were only silently dropped
	# rather than rejected, evict the real keyring package from the archive
	# with no signal that anything was wrong.
	if [[ "$(basename "$deb")" == glyndor-archive-keyring* ]]; then
		echo "::error::$(basename "$deb") has the reserved keyring name glyndor-archive-keyring; a product must not ship an asset under this filename" >&2
		exit 1
	fi

	# Reject the reserved keyring package name on the *control* field, not just
	# the filename: a product could ship a normally-named, validly-signed .deb
	# whose internal Package is glyndor-archive-keyring and so shadow the real
	# keyring in the archive. The keyring is built locally, never downloaded.
	# A control field dpkg-deb cannot read is a hard error: an unreadable
	# package must not slip past the reserved-name gate unclassified.
	if ! pkg="$(dpkg-deb -f "$deb" Package)"; then
		echo "::error::cannot read the Package control field of $(basename "$deb"); refusing an unreadable package" >&2
		exit 1
	fi
	if [ "$pkg" = "glyndor-archive-keyring" ]; then
		echo "::error::$(basename "$deb") declares the reserved package name glyndor-archive-keyring; a product must not ship the keyring package" >&2
		exit 1
	fi

	# Bind the verified package to the product it was downloaded from. Without
	# this, any product's compromised release could sign a .deb whose control
	# Package (and filename) claims to be a different, unrelated product, since the
	# signature alone would still verify, since the release key is shared.
	if [ -n "$EXPECTED_PACKAGE" ]; then
		if [ "$pkg" != "$EXPECTED_PACKAGE" ]; then
			echo "::error::package name mismatch: $(basename "$deb") declares '$pkg', expected '$EXPECTED_PACKAGE'" >&2
			exit 1
		fi
		if [[ "$(basename "$deb")" != "${EXPECTED_PACKAGE}_"* ]]; then
			echo "::error::package name mismatch: $(basename "$deb") filename does not start with '${EXPECTED_PACKAGE}_'" >&2
			exit 1
		fi
	fi

	# Bind the package to the RELEASE it came from, not just to the product.
	#
	# The signature covers the bytes and says nothing about which tag they were
	# attached to, and the archive is rebuilt latest-only from whatever the
	# newest release carries. So without this, an actor who can publish a
	# release, and who needs no signing key at all, re-attaches a previously
	# published and still validly signed .deb to a new tag: the signature
	# verifies, the control Package matches, the filename prefix matches, and
	# the archive is pinned to the old version for every install that follows.
	# Measured 2026-09-07: podup_5.4.0_amd64.deb, five releases behind what was
	# being served, passed this script with exit 0.
	#
	# Compare the upstream part only. A Debian version may carry an epoch
	# (`1:5.9.2`) and a revision (`5.9.2-1`), and neither belongs to the tag;
	# rejecting those would refuse a legitimate repackage. The tag's leading `v`
	# is dropped for the same reason, in the other direction.
	if [ -n "$EXPECTED_TAG" ]; then
		if ! ver="$(dpkg-deb -f "$deb" Version)"; then
			echo "::error::cannot read the Version control field of $(basename "$deb"); refusing a package whose version cannot be bound to its release" >&2
			exit 1
		fi
		upstream="${ver#*:}"
		upstream="${upstream%-*}"
		want="${EXPECTED_TAG#v}"
		if [ "$upstream" != "$want" ]; then
			echo "::error::version mismatch: $(basename "$deb") declares '$ver' but was downloaded from release '$EXPECTED_TAG'; a release must not carry a .deb built for another one" >&2
			exit 1
		fi
	fi

	sig="$deb.sig"
	if [ ! -f "$sig" ]; then
		echo "::error::no signature ($sig) for $(basename "$deb"); refusing to publish an unverified package" >&2
		exit 1
	fi

	# Capture the verifier's exit code (rather than just its pass/fail status)
	# so the message below can tell a malformed local trust anchor apart from
	# an untrusted signature that plainly fails verification. Conflating the
	# two previously reported "release may be tampered" even when the real
	# cause was our own key file, which sent whoever was debugging it looking
	# for an attack that wasn't there.
	python_rc=0
	python3 - "$sig" "$deb" "${KEYS[@]}" <<'PYEOF' || python_rc=$?
import base64
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

sig_path, data_path, keys_b64 = sys.argv[1], sys.argv[2], sys.argv[3:]


def load(b64):
	# Normalise padding to a 4-char boundary and reject any non-base64 input,
	# rather than blindly appending pad characters.
	b64 += "=" * (-len(b64) % 4)
	key_bytes = base64.b64decode(b64, validate=True)
	if len(key_bytes) != 32:
		raise ValueError("release public key is not a 32-byte Ed25519 key")
	return Ed25519PublicKey.from_public_bytes(key_bytes)


try:
	keys = [load(b64) for b64 in keys_b64]
except (ValueError, base64.binascii.Error) as exc:
	sys.stderr.write(f"malformed release public key: {exc}\n")
	sys.exit(2)
if not keys:
	sys.stderr.write("no release public keys provided\n")
	sys.exit(2)

# An Ed25519 detached signature is exactly 64 bytes. Read at most one byte
# past a generous 4096-byte cap rather than the whole file: a hostile or
# corrupt .sig asset must not be read into memory wholesale before its length
# is even checked.
#
# Both checks below exit 1, not 2: exit 2 is reserved for a malformed LOCAL
# trust anchor (the committed key file this script itself was given), so the
# caller can tell "our config is broken" apart from "the downloaded asset is
# bad". An oversized or wrong-length .sig is the latter, untrusted data the
# release supplied rather than our key material, so it belongs in the same bucket
# as a signature that fails cryptographic verification below.
MAX_SIG_BYTES = 4096
with open(sig_path, "rb") as f:
	sig = f.read(MAX_SIG_BYTES + 1)
if len(sig) > MAX_SIG_BYTES:
	sys.stderr.write(f"signature file is over {MAX_SIG_BYTES} bytes\n")
	sys.exit(1)
if len(sig) != 64:
	sys.stderr.write(f"signature is {len(sig)} bytes, expected exactly 64 (Ed25519 detached signature)\n")
	sys.exit(1)
# Unbounded read: this loads the whole .deb into memory, so callers must bound
# the input file's size before invoking this script. publish.yml enforces
# MAX_DEB_BYTES both pre-download (against the advertised release asset size)
# and post-download (against the bytes actually written to disk).
with open(data_path, "rb") as f:
	data = f.read()

# Admit the package if any trusted key verifies it (rotation overlap).
for key in keys:
	try:
		key.verify(sig, data)
		sys.exit(0)
	except InvalidSignature:
		continue
sys.exit(1)
PYEOF
	if [ "$python_rc" -ne 0 ]; then
		if [ "$python_rc" -eq 2 ]; then
			# Our bug: the committed release public key file failed to load, so
			# no key was even available to check the signature against.
			echo "::error::local release trust file is malformed; could not load a release public key to verify $(basename "$deb") against" >&2
		else
			# Their bug: a key loaded fine, but $(basename "$deb")'s signature did
			# not verify against any of them.
			echo "::error::invalid signature for $(basename "$deb"); release may be tampered" >&2
		fi
		exit 1
	fi

	echo "verified $(basename "$deb")"
	count=$((count + 1))
done

echo "verified $count product package(s) against the release key"
