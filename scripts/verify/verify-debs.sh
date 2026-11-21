#!/usr/bin/env bash
#
# Verify every product .deb in a directory against its detached Ed25519 .sig
# using the shared Glyndor release public key. Fails closed: a missing or
# invalid signature aborts the publish, so the archive never re-signs (and
# vouches for, with its own GPG key) a binary it did not verify.
#
# Each product's release workflow signs its .deb with the org release signing
# key and attaches a <deb>.sig asset. This is
# a separate trust anchor from the apt archive GPG key: the release key proves
# the upstream binary is authentic; the archive key proves the repository
# metadata is authentic.
#
# The key file carries one base64-encoded Ed25519 public key per line. More than
# one key may be present so a two-phase release-key rotation can trust the old
# and the new key at once during the overlap: a .deb is admitted if any listed
# key verifies it. Blank lines and lines starting with '#' are ignored.
#
# A second, post-quantum signature may sit beside the first: <deb>.mldsa65.sig,
# the raw ML-DSA-65 (FIPS 204) signature over the same bytes. It is a hybrid,
# never a replacement: the Ed25519 signature is checked first and always, and
# when the second one is present it must verify as well. A product listed in
# the required file must carry it, because a second signature that may be left
# out protects nothing; whoever can forge the first one simply drops it. A
# present second signature with no ML-DSA-65 key configured is refused, since a
# signature that cannot be checked is not one that passed.
#
# Requires: python3 with the `cryptography` module, and dpkg-deb. The ML-DSA-65
# check needs cryptography 50.0.2 or later (scripts/verify/verify-debs-
# requirements.txt), and only when there is a second signature to check.
#
# Usage:
#   verify-debs.sh [--require-tag] <debs-dir> [<pubkey-b64-file>] [<expected_package>]
#                  [<expected_tag>] [<mldsa65-pubkey-b64-file>] [<pq-required-file>]
#
# The ML-DSA-65 key file has the same format as the Ed25519 one, a raw 1952-byte
# key per line. The required file names one Debian package per line, and a
# comment takes a line of its own: an entry that is not a Debian package name
# (`podup # since 2.0`, `Podup`) refuses the run as a malformed local file, since
# read as a name it would match nothing and drop the requirement in silence.
# Either file may be absent, which reads as no key and no product required.
#
# Whether a .deb is required is decided by its control Package field, which is
# bound to the product only when expected_package is given. So while the
# required file lists any product, expected_package is mandatory and its
# absence refuses the run; with the list empty nothing changes.
#
# When expected_tag is given, every .deb must declare a Version whose upstream
# part equals that tag without its leading `v`. The signature covers the bytes
# and not the tag they were attached to, so this is what stops a still-valid
# .deb from an older release being re-attached to a new one.
#
# An empty expected_tag means "do not bind to a release", which is what the suite
# needs to exercise the other gates on their own and the opposite of what a
# publish needs. --require-tag makes the binding mandatory: with it, an absent
# or empty expected_tag refuses the run here, so the caller cannot turn the
# check off by handing over an empty value, and no check of its own has to stay
# in place for the binding to hold.
#
# When expected_package is given, every .deb in debs-dir must also declare it
# as the control Package field AND carry it as the filename prefix
# ("<expected_package>_..."). The release key is shared by every Glyndor
# product, so a valid signature alone does not prove a .deb is the product it
# was downloaded from, since a compromised release could otherwise ship an asset
# whose control Package (and/or filename) claims to be a different product.

set -euo pipefail

REQUIRE_TAG=0
if [ "${1:-}" = "--require-tag" ]; then
	REQUIRE_TAG=1
	shift
fi
DEBS_DIR="${1:?usage: verify-debs.sh [--require-tag] <debs-dir> [<pubkey-b64-file>] [<expected_package>] [<expected_tag>]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY_FILE="${2:-$HERE/keyring/glyndor-release-ed25519.b64}"
EXPECTED_PACKAGE="${3:-}"
# The release tag the directory was downloaded from, e.g. v5.9.2. Optional so
# the suite can exercise the other gates on their own, and passed by publish.yml
# from the tag it already pinned per product, together with --require-tag.
EXPECTED_TAG="${4:-}"
if [ "$REQUIRE_TAG" -eq 1 ] && [ -z "$EXPECTED_TAG" ]; then
	echo "::error::--require-tag was given but the expected tag is empty; refusing to admit the packages in $DEBS_DIR, which cannot be bound to a release" >&2
	exit 1
fi
MLDSA_KEY_FILE="${5:-$HERE/keyring/glyndor-release-mldsa65.b64}"
PQ_REQUIRED_FILE="${6:-$HERE/keyring/pq-required-products}"

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

# One entry per non-empty, non-comment line, whitespace stripped, as above. A
# missing file reads as empty: no ML-DSA-65 key is configured yet, and the
# caller may run this from a tree that predates the second signature.
read_list() { # <file> [trim]: with `trim` only the ends of a line are stripped
	local line
	[ -e "$1" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "${2:-}" = trim ]; then
			line="${line#"${line%%[![:space:]]*}"}"
			line="${line%"${line##*[![:space:]]}"}"
		else
			line="$(printf '%s' "$line" | tr -d '[:space:]')"
		fi
		case "$line" in '' | '#'*) continue ;; esac
		printf '%s\n' "$line"
	done < "$1"
}
# A file that exists and cannot be read is an error, not an empty list: an
# unreadable required file would otherwise drop every product from it.
mldsa_keys="$(read_list "$MLDSA_KEY_FILE")" \
	|| { echo "::error::cannot read the ML-DSA-65 release public key file $MLDSA_KEY_FILE" >&2; exit 1; }
pq_required="$(read_list "$PQ_REQUIRED_FILE" trim)" \
	|| { echo "::error::cannot read the required-products file $PQ_REQUIRED_FILE" >&2; exit 1; }
MLDSA_KEYS=()
[ -z "$mldsa_keys" ] || mapfile -t MLDSA_KEYS <<< "$mldsa_keys"
PQ_REQUIRED=()
[ -z "$pq_required" ] || mapfile -t PQ_REQUIRED <<< "$pq_required"
for name in "${PQ_REQUIRED[@]}"; do
	if ! [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
		echo "::error::local required-products file $PQ_REQUIRED_FILE is malformed: '$name' is not a Debian package name; a comment takes a line of its own" >&2
		exit 1
	fi
done
if [ "${#PQ_REQUIRED[@]}" -ge 1 ] && [ -z "$EXPECTED_PACKAGE" ]; then
	echo "::error::$PQ_REQUIRED_FILE requires the ML-DSA-65 signature of some products and no expected_package was given, so whether these packages are required cannot be decided; pass the product name" >&2
	exit 1
fi

# Check the ML-DSA-65 key file, or one signature against it. Exit 0 verified, 1
# the downloaded signature is bad, 2 our own key file is malformed, 3 the
# installed cryptography cannot verify ML-DSA. The library is imported only
# after the key file and the signature's length are checked, so neither of
# those needs it, and nothing here needs it while no release carries a second
# signature: the runner's python3-cryptography has no ML-DSA.
mldsa() { # check-keys | verify <sig> <deb>, then the keys
	python3 - "$@" <<'PYEOF'
import base64
import binascii
import sys

PUBLIC_KEY_BYTES = 1952  # FIPS 204, ML-DSA-65
SIGNATURE_BYTES = 3309
# The same 4096-byte read cap as the Ed25519 signature and as publish.yml's
# per-asset .sig cap: a hostile sidecar is never read whole before its length
# is known.
MAX_SIG_BYTES = 4096

mode = sys.argv[1]
if mode == "check-keys":
	sig_path = data_path = None
	keys_b64 = sys.argv[2:]
else:
	sig_path, data_path, keys_b64 = sys.argv[2], sys.argv[3], sys.argv[4:]


def decode(b64):
	b64 += "=" * (-len(b64) % 4)
	raw = base64.b64decode(b64, validate=True)
	if len(raw) != PUBLIC_KEY_BYTES:
		raise ValueError(f"key is {len(raw)} bytes, not a {PUBLIC_KEY_BYTES}-byte ML-DSA-65 public key")
	return raw


try:
	raw_keys = [decode(b64) for b64 in keys_b64]
except (ValueError, binascii.Error) as exc:
	sys.stderr.write(f"malformed ML-DSA-65 release public key: {exc}\n")
	sys.exit(2)
if not raw_keys:
	sys.stderr.write("no ML-DSA-65 release public keys provided\n")
	sys.exit(2)
if mode == "check-keys":
	sys.exit(0)

try:
	with open(sig_path, "rb") as f:
		pq_sig = f.read(MAX_SIG_BYTES + 1)
except OSError as exc:
	sys.stderr.write(f"cannot read the ML-DSA-65 signature file: {exc}\n")
	sys.exit(1)
if len(pq_sig) > MAX_SIG_BYTES:
	sys.stderr.write(f"ML-DSA-65 signature file is over {MAX_SIG_BYTES} bytes\n")
	sys.exit(1)
if len(pq_sig) != SIGNATURE_BYTES:
	sys.stderr.write(f"ML-DSA-65 signature is {len(pq_sig)} bytes, expected exactly {SIGNATURE_BYTES}\n")
	sys.exit(1)

from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm

try:
	from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PublicKey

	keys = [MLDSA65PublicKey.from_public_bytes(raw) for raw in raw_keys]
except (ImportError, UnsupportedAlgorithm) as exc:
	sys.stderr.write(
		f"the installed cryptography module cannot verify ML-DSA-65 ({exc}); "
		"cryptography 50.0.2 or later is required, pinned in scripts/verify/verify-debs-requirements.txt\n"
	)
	sys.exit(3)
except ValueError as exc:
	sys.stderr.write(f"malformed ML-DSA-65 release public key: {exc}\n")
	sys.exit(2)

# Bounded by the caller, as for the Ed25519 check: publish.yml caps the .deb.
with open(data_path, "rb") as f:
	data = f.read()
# Pure ML-DSA with the empty context, so `openssl pkeyutl -verify -rawin` 3.5
# or later checks the same signature. Any listed key may verify it (rotation).
for key in keys:
	try:
		key.verify(pq_sig, data)
		sys.exit(0)
	except InvalidSignature:
		continue
sys.exit(1)
PYEOF
}

# Our own trust anchor is checked before any package: a broken key file is a
# configuration error whether or not this run meets a second signature.
if [ "${#MLDSA_KEYS[@]}" -ge 1 ] && ! mldsa check-keys "${MLDSA_KEYS[@]}"; then
	echo "::error::local ML-DSA-65 release trust file $MLDSA_KEY_FILE is malformed" >&2
	exit 1
fi

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

	# The second signature, over the same raw bytes and checked only after the
	# first one passed. A sidecar that is present is checked here, before the
	# package is opened; whether a missing one is allowed depends on the control
	# Package field, so that is decided below, once the field has been read.
	pq_sig="$deb.mldsa65.sig"
	if [ -e "$pq_sig" ] || [ -L "$pq_sig" ]; then
		if [ "${#MLDSA_KEYS[@]}" -eq 0 ]; then
			echo "::error::$(basename "$deb") carries an ML-DSA-65 signature and no ML-DSA-65 release public key is configured in $MLDSA_KEY_FILE; refusing a signature that cannot be checked" >&2
			exit 1
		fi
		pq_rc=0
		mldsa verify "$pq_sig" "$deb" "${MLDSA_KEYS[@]}" || pq_rc=$?
		case "$pq_rc" in
			0) ;;
			2)
				echo "::error::local ML-DSA-65 release trust file is malformed; could not load a key to verify $(basename "$deb") against" >&2
				exit 1
				;;
			3)
				echo "::error::cannot verify the ML-DSA-65 signature of $(basename "$deb"): the installed cryptography has no ML-DSA support; refusing rather than skipping it" >&2
				exit 1
				;;
			*)
				echo "::error::invalid ML-DSA-65 signature for $(basename "$deb"); release may be tampered" >&2
				exit 1
				;;
		esac
	fi

	# Only now is the package opened. dpkg-deb parses the archive to read its
	# control fields, and every byte of it comes from whoever can attach a
	# release asset: a parser bug reached by those bytes would run in the
	# publish job, which later holds the archive signing key and the bucket
	# credentials. So nothing reads inside the package before a release key has
	# vouched for exactly these bytes, and everything above looks only at the
	# file names and at the bytes as bytes.

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
		# Strip the Debian revision only when it looks like one: it starts with a
		# digit (`-1`, `-3ubuntu1`). A suffix that starts with a letter (`-rc1`,
		# `-beta2`) is part of a pre-release version, and cutting it would admit a
		# signed 5.10.0-rc1 package as the stable v5.10.0.
		revision="${upstream##*-}"
		if [ "$revision" != "$upstream" ] && [[ "$revision" =~ ^[0-9][0-9A-Za-z.+~]*$ ]]; then
			upstream="${upstream%-*}"
		fi
		want="${EXPECTED_TAG#v}"
		# A tag with a hyphen (v5.10.0-rc1) is ambiguous: dpkg reads the text
		# after the last hyphen as the revision. Accept the whole version as
		# well, still equal to the tag, and nothing looser.
		if [ "$upstream" != "$want" ] && [ "${ver#*:}" != "$want" ]; then
			echo "::error::version mismatch: $(basename "$deb") declares '$ver' but was downloaded from release '$EXPECTED_TAG'; a release must not carry a .deb built for another one" >&2
			exit 1
		fi
	fi

	# Bind the package's architecture to the one its name claims. The filename
	# is set by whoever uploads the release asset and is not part of the signed
	# bytes, so a single signed amd64 .deb can be attached twice under both the
	# `_amd64.deb` and `_arm64.deb` names and the gate would otherwise admit
	# both, leaving arm64 users with no package. The control Architecture field
	# is inside the signed payload, so I read it back to learn the architecture
	# the build actually produced and trust that one instead.
	if ! ctrl_arch="$(dpkg-deb -f "$deb" Architecture)"; then
		echo "::error::cannot read the Architecture control field of $(basename "$deb"); refusing a package whose architecture cannot be bound to its name" >&2
		exit 1
	fi
	base="$(basename "$deb")"
	claimed_arch=""
	case "$base" in
		*_*.deb)
			claimed_arch="${base##*_}"
			claimed_arch="${claimed_arch%.deb}"
			;;
	esac
	if [ -n "$claimed_arch" ] && [ "$claimed_arch" != "$ctrl_arch" ]; then
		echo "::error::architecture mismatch: $base is named for $claimed_arch but its control field says $ctrl_arch; a release must not carry a package built for another architecture under this name" >&2
		exit 1
	fi

	# A product in the required list must carry the second signature. Keyed on
	# the control Package field, which is inside the signed bytes and already
	# bound to expected_package above, so a renamed asset cannot leave the list.
	required=0
	for name in "${PQ_REQUIRED[@]}"; do
		[ "$name" = "$pkg" ] && required=1
	done
	if [ "$required" -eq 1 ] && [ ! -e "$pq_sig" ] && [ ! -L "$pq_sig" ]; then
		echo "::error::no ML-DSA-65 signature ($pq_sig) for $(basename "$deb"); $pkg requires the hybrid release signature" >&2
		exit 1
	fi

	echo "verified $(basename "$deb")"
	count=$((count + 1))
done

echo "verified $count product package(s) against the release key"
