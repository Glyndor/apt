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
#   verify-debs.sh <debs-dir> [<pubkey-b64-file>]

set -euo pipefail

DEBS_DIR="${1:?usage: verify-debs.sh <debs-dir> [<pubkey-b64-file>]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${2:-$HERE/keyring/glyndor-release-ed25519.b64}"

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
	# verified with no exceptions — keying a skip on the filename would let a
	# product publish an asset under a trusted name to bypass the check. The
	# locally-built keyring package is produced in a later step (build-keyring),
	# after this runs, and is signed by the archive key, not the release key.

	# Reject the reserved keyring package name on the *control* field, not just
	# the filename: a product could ship a normally-named, validly-signed .deb
	# whose internal Package is glyndor-archive-keyring and so shadow the real
	# keyring in the archive. The keyring is built locally, never downloaded.
	# A control field dpkg-deb cannot read is a hard error — an unreadable
	# package must not slip past the reserved-name gate unclassified.
	if ! pkg="$(dpkg-deb -f "$deb" Package)"; then
		echo "::error::cannot read the Package control field of $(basename "$deb") — refusing an unreadable package" >&2
		exit 1
	fi
	if [ "$pkg" = "glyndor-archive-keyring" ]; then
		echo "::error::$(basename "$deb") declares the reserved package name glyndor-archive-keyring — a product must not ship the keyring package" >&2
		exit 1
	fi

	sig="$deb.sig"
	if [ ! -f "$sig" ]; then
		echo "::error::no signature ($sig) for $(basename "$deb") — refusing to publish an unverified package" >&2
		exit 1
	fi

	if ! python3 - "$sig" "$deb" "${KEYS[@]}" <<'PYEOF'
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

with open(sig_path, "rb") as f:
	sig = f.read()
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
	then
		echo "::error::invalid signature for $(basename "$deb") — release may be tampered" >&2
		exit 1
	fi

	echo "verified $(basename "$deb")"
	count=$((count + 1))
done

echo "verified $count product package(s) against the release key"
