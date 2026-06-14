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
# Requires: python3 with the `cryptography` module.
#
# Usage:
#   verify-debs.sh <debs-dir> [<pubkey-b64-file>]

set -euo pipefail

DEBS_DIR="${1:?usage: verify-debs.sh <debs-dir> [<pubkey-b64-file>]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${2:-$HERE/keyring/glyndor-release-ed25519.b64}"

[ -f "$KEY_FILE" ] || { echo "::error::release public key $KEY_FILE not found" >&2; exit 1; }
PUBKEY_B64="$(tr -d '[:space:]' < "$KEY_FILE")"
[ -n "$PUBKEY_B64" ] || { echo "::error::release public key $KEY_FILE is empty" >&2; exit 1; }

shopt -s nullglob
debs=("$DEBS_DIR"/*.deb)
[ "${#debs[@]}" -ge 1 ] || { echo "::error::no .deb files to verify in $DEBS_DIR" >&2; exit 1; }

count=0
for deb in "${debs[@]}"; do
	# The keyring package is built locally in this repo (not a signed upstream
	# release asset), so it has no .sig and is signed only by the archive key.
	case "$(basename "$deb")" in
	glyndor-archive-keyring*.deb) continue ;;
	esac

	sig="$deb.sig"
	if [ ! -f "$sig" ]; then
		echo "::error::no signature ($sig) for $(basename "$deb") — refusing to publish an unverified package" >&2
		exit 1
	fi

	if ! python3 - "$PUBKEY_B64" "$sig" "$deb" <<'PYEOF'
import base64
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

pubkey_b64, sig_path, data_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(sig_path, "rb") as f:
	sig = f.read()
with open(data_path, "rb") as f:
	data = f.read()
try:
	Ed25519PublicKey.from_public_bytes(base64.b64decode(pubkey_b64 + "==")).verify(sig, data)
except InvalidSignature:
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
