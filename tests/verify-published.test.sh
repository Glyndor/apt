#!/usr/bin/env bash
#
# Tests for scripts/verify-published.sh, the gate that reads the published
# archive back and refuses to call a publish successful unless every file the
# signed index declares is served at exactly the size and hash it was signed
# with. Each case asserts the script's exit status (0 = archive consistent,
# non-zero = rejected) so a regression that lets a broken archive through
# fails CI.
#
# A synthetic archive is built, signed with an ephemeral key and served over a
# local HTTP server, then mutated per case. Serving over http:// is deliberate:
# the script's trust anchor is the archive key, not the transport, and the tests
# exercise the same path production does.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$HERE/scripts/verify-published.sh"
WORK="$(mktemp -d)"
SITE="$WORK/site"
DIST="$SITE/dists/stable"
GNUPGHOME="$WORK/gnupg"
export GNUPGHOME
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0

# assert <expected-exit> <description> -- <command...>
assert() {
	local want="$1" desc="$2"
	shift 3 # drop want, desc, and the literal "--"
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want, got $got)"
		fail=$((fail + 1))
	fi
}

# assert_says <expected-exit> <needle> <description> -- <command...>
# For asserting something about a run that is expected to succeed: what it
# reports, not just that it exited zero.
assert_says() {
	local want="$1" needle="$2" desc="$3"
	shift 4
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF "$needle"; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want saying '$needle', got exit $got)"
		printf '%s\n' "$out" | sed 's/^/       /'
		fail=$((fail + 1))
	fi
}

# assert_error <expected-exit> <needle> <description> -- <command...>
# Same as assert, but also requires the combined output to contain needle, so a
# rejection is checked for the right reason rather than for any reason at all.
assert_error() {
	local want="$1" needle="$2" desc="$3"
	shift 4
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF "$needle"; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got)"
		printf '%s\n' "$out" | sed 's/^/       /'
		fail=$((fail + 1))
	fi
}

# --- Keys --------------------------------------------------------------------

# Two keys: the one the archive is signed with and imported by the script under
# test, and an untrusted one used to prove a valid signature from the wrong key
# is still a rejection.
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key "Glyndor Test Archive" ed25519 sign never
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key "Untrusted Signer" ed25519 sign never

TRUSTED_KEY="$(gpg --batch --with-colons --list-keys "Glyndor Test Archive" | awk -F: '/^fpr:/{print $10; exit}')"
UNTRUSTED_KEY="$(gpg --batch --with-colons --list-keys "Untrusted Signer" | awk -F: '/^fpr:/{print $10; exit}')"
TRUSTED_ASC="$WORK/trusted.asc"
gpg --batch --quiet --armor --export "$TRUSTED_KEY" > "$TRUSTED_ASC"

# --- Archive construction ----------------------------------------------------

# The keyring package is architecture-independent, so it is declared in every
# architecture's Packages. That is what makes it the dedup case: four
# declarations across two architectures, three distinct objects.
PODUP_POOL="pool/main/p/podup"
KEYRING_POOL="pool/main/g/glyndor-archive-keyring"
# The '+' is deliberate: a real Debian version carries one, and the path
# validation has to allow it without allowing traversal.
KEYRING_DEB="$KEYRING_POOL/glyndor-archive-keyring_1.0.0+key1_all.deb"

# write_pool: the .deb objects the indices point at.
write_pool() {
	local arch
	mkdir -p "$SITE/$PODUP_POOL" "$SITE/$KEYRING_POOL"
	for arch in amd64 arm64; do
		printf 'fake podup deb for %s\n' "$arch" > "$SITE/$PODUP_POOL/podup_1.12.0_${arch}.deb"
	done
	printf 'fake keyring deb\n' > "$SITE/$KEYRING_DEB"
}

# stanza <package> <architecture> <pool-path>: one Packages entry, declaring
# the pool object the way a real index does.
stanza() {
	printf 'Package: %s\nVersion: 1.12.0\nArchitecture: %s\nFilename: %s\nSize: %s\nSHA256: %s\n\n' \
		"$1" "$2" "$3" \
		"$(stat -c%s "$SITE/$3")" \
		"$(sha256sum "$SITE/$3" | cut -d' ' -f1)"
}

# write_indices: the index files a two-architecture reprepro export produces.
write_indices() {
	local arch
	write_pool
	for arch in amd64 arm64; do
		mkdir -p "$DIST/main/binary-$arch"
		{
			stanza podup "$arch" "$PODUP_POOL/podup_1.12.0_${arch}.deb"
			stanza glyndor-archive-keyring all "$KEYRING_DEB"
		} > "$DIST/main/binary-$arch/Packages"
		printf 'Archive: stable\nComponent: main\nArchitecture: %s\n' "$arch" \
			> "$DIST/main/binary-$arch/Release"
	done
}

# write_release <signing-key>: the Release body plus both signed forms.
write_release() {
	local key="$1" f
	{
		echo "Origin: Glyndor"
		echo "Label: Glyndor"
		echo "Suite: stable"
		echo "Codename: stable"
		echo "Architectures: amd64 arm64"
		echo "Components: main"
		echo "Date: $(date -u -R)"
		echo "SHA256:"
		while IFS= read -r f; do
			printf ' %s %s %s\n' \
				"$(sha256sum "$DIST/$f" | cut -d' ' -f1)" \
				"$(stat -c%s "$DIST/$f")" \
				"$f"
		done < <(cd "$DIST" && find main -type f | sort)
	} > "$DIST/Release"
	rm -f "$DIST/InRelease" "$DIST/Release.gpg"
	gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
		--local-user "$key" --clearsign --output "$DIST/InRelease" "$DIST/Release"
	gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
		--local-user "$key" --armor --detach-sign --output "$DIST/Release.gpg" "$DIST/Release"
}

# build_archive [<signing-key>]: a consistent archive, from scratch.
build_archive() {
	rm -rf "$SITE"
	mkdir -p "$DIST"
	write_indices
	write_release "${1:-$TRUSTED_KEY}"
}

# --- Local HTTP server -------------------------------------------------------

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
BASE="http://127.0.0.1:$PORT"

build_archive
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER_PID=$!

# Poll for readiness rather than sleeping a guessed interval, so the suite is
# deterministic on a slow runner.
for _ in $(seq 1 50); do
	if curl -fsS --max-time 2 "$BASE/dists/stable/InRelease" -o /dev/null 2>/dev/null; then
		break
	fi
	sleep 0.2
done
curl -fsS --max-time 2 "$BASE/dists/stable/InRelease" -o /dev/null \
	|| { echo "local HTTP server never came up on $PORT" >&2; exit 1; }

# One attempt and no delay unless a case is specifically about retrying, so a
# rejection is reported immediately instead of after the production schedule.
run() { "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0; }

# --- Cases -------------------------------------------------------------------

build_archive
assert 0 "a consistent archive is accepted" -- run

build_archive
rm "$DIST/main/binary-arm64/Packages"
assert_error 1 "main/binary-arm64/Packages" "a declared file that 404s is rejected" -- run

build_archive
printf 'Package: podup\nVersion: 1.12.0\nArchitecture: arm64\nextra\n\n' \
	> "$DIST/main/binary-arm64/Packages"
assert_error 1 "size mismatch" "a declared file served at the wrong size is rejected" -- run

build_archive
# Same length, different bytes: the size check passes and only the hash catches
# it, which is the case a size-only comparison would wave through.
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
assert_error 1 "hash mismatch" "a declared file served with the wrong content is rejected" -- run

build_archive "$UNTRUSTED_KEY"
assert_error 1 "signature verification failed" "an index signed by an untrusted key is rejected" -- run

build_archive
cp "$DIST/Release" "$DIST/InRelease"
assert_error 1 "signature verification failed" "an unsigned index is rejected" -- run

build_archive
# Same case as above, but the unsigned fixture is valid OpenPGP: a literal data
# packet that any OpenPGP parser will accept. A plain-text "unsigned index" is
# refused as not-OpenPGP, which proves nothing about the signature rule; this
# case is what catches a verifier that accepts an unsigned packet because it
# parsed cleanly. The header (0xcb: new-format tag 11, one-octet length) keeps
# the body short enough for the one-octet length encoding to stay valid.
python3 - "$DIST/InRelease" <<'PY'
import sys
body = b"Date: Sun, 06 Sep 2026 09:47:38 UTC\nSHA256:\n abc 1 x\n"
packet = b"b\x00" + bytes(4) + body
open(sys.argv[1], "wb").write(bytes([0xcb, len(packet)]) + packet)
PY
assert_error 1 "signature verification failed" "an OpenPGP literal data packet with no signature is rejected" -- run

build_archive
rm "$DIST/Release.gpg"
assert_error 1 "detached Release" "a missing detached signature is rejected" -- run

build_archive
# Re-sign a Release that no longer matches InRelease: the archive is serving
# two different builds to two different client paths.
printf 'Origin: Glyndor\nSHA256:\n 00 1 main/binary-amd64/Packages\n' > "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign --yes \
	--output "$DIST/Release.gpg" "$DIST/Release"
assert_error 1 "different files" "an index whose detached half disagrees is rejected" -- run

build_archive
printf 'Origin: Glyndor\nSuite: stable\n' > "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --clearsign --yes --output "$DIST/InRelease" "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign --yes --output "$DIST/Release.gpg" "$DIST/Release"
assert_error 1 "declares no SHA256 entries" "an index with no SHA256 section is rejected" -- run

build_archive
# A signed document is authentic, not safe. The key that signs it is the one
# thing this script cannot second-guess, so a traversal path must still be
# refused rather than pasted into a URL.
{
	echo "Origin: Glyndor"
	echo "SHA256:"
	echo " 00 1 main/../../etc/passwd"
} > "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --clearsign --yes --output "$DIST/InRelease" "$DIST/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--local-user "$TRUSTED_KEY" --armor --detach-sign --yes --output "$DIST/Release.gpg" "$DIST/Release"
assert_error 1 "not a plain relative path" "a traversal path in the signed index is rejected" -- run

# The bug this script exists for: a file that is missing when the publish
# finishes and appears moments later. The restore is scheduled before the run
# so the first pass reliably misses it and a later pass reliably finds it, which
# keeps the case deterministic rather than racing the retry schedule.
build_archive
cp "$DIST/main/binary-arm64/Packages" "$WORK/delayed"
rm "$DIST/main/binary-arm64/Packages"
(sleep 2 && cp "$WORK/delayed" "$DIST/main/binary-arm64/Packages") &
restore_pid=$!
assert 0 "a file that becomes visible late is accepted after a retry" -- \
	"$VERIFY" "$BASE" "$TRUSTED_ASC" 6 1
# Wait on the restore specifically. A bare `wait` would also wait on the HTTP
# server, which is a background job of this same shell and never exits.
wait "$restore_pid"

build_archive
assert_error 1 "could not fetch" "an unreachable archive is rejected" -- \
	"$VERIFY" "http://127.0.0.1:1" "$TRUSTED_ASC" 1 0

# --- The pool: the link the indices vouch for --------------------------------

build_archive
rm "$SITE/$PODUP_POOL/podup_1.12.0_arm64.deb"
assert_error 1 "podup_1.12.0_arm64.deb" "a declared package that 404s is rejected" -- run

build_archive
# Same length, different bytes. The indices still verify; only the package does
# not, which is the case an index-only check waves through.
sed -i 's/fake podup deb for arm64/fake podup deb for ar_64/' \
	"$SITE/$PODUP_POOL/podup_1.12.0_arm64.deb"
assert_error 1 "hash mismatch" "a declared package served with the wrong content is rejected" -- run

build_archive
# Four declarations across two architectures, three distinct objects: the
# architecture-independent keyring must not be fetched once per architecture.
assert_says 0 "declare 3 package(s)" "an architecture-independent package is checked once, not per architecture" -- run

build_archive
: > "$DIST/main/binary-amd64/Packages"
: > "$DIST/main/binary-arm64/Packages"
write_release "$TRUSTED_KEY"
assert_error 1 "declare no packages" "an archive whose indices declare no installable package is rejected" -- run

build_archive
# The second link of the chain needs the same path validation as the first: a
# verified index is authentic, and authentic is still not safe.
sed -i "s|Filename: $PODUP_POOL/podup_1.12.0_amd64.deb|Filename: pool/../../etc/passwd|" \
	"$DIST/main/binary-amd64/Packages"
write_release "$TRUSTED_KEY"
assert_error 1 "not a plain relative path" "a traversal path in a verified index is rejected" -- run

# --- The caps: bounded work, not just bounded objects ------------------------
# The two caps are the only thing keeping a hostile or runaway index from
# turning this gate into an unbounded download. They are exercised here by
# lowering them below what the fixture declares, because an archive large
# enough to trip the defaults is not a fixture anybody should build.
build_archive
assert_error 1 "over the 3 cap" "an index declaring more files than the entry cap is rejected" -- \
	env VERIFY_PUBLISHED_MAX_ENTRIES=3 "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0
assert_error 1 "bytes of packages, over the 1 cap" "indices declaring more package bytes than the pool cap are rejected" -- \
	env VERIFY_PUBLISHED_MAX_POOL_BYTES=1 "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0
assert 0 "the caps at their defaults accept the same archive" -- run

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
