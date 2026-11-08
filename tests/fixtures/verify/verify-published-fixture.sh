#!/usr/bin/env bash
#
# The shared fixture for the verify-published suites.
#
# It is sourced, not executed: it creates the ephemeral signing keys, builds
# and signs a synthetic archive, serves it over a local HTTP server and
# provides the three assertion helpers. The suites that source it mutate the
# archive per case and read the result.
#
# Three suites source it:
#
#   tests/verify/verify-published.test.sh            the index and the pool
#   tests/verify/verify-published/verify-published-bootstrap.test.sh  the bootstrap pair
#   tests/verify/verify-published/verify-published-budget.test.sh      the budgets and the caps
#
# Serving over http:// is deliberate: the script's trust anchor is the archive
# key, not the transport, and the tests exercise the same path production does.
#
# Requires: gpg, curl, python3, sha256sum.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-published.sh"
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
	timeout 10 gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

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
# Read by the bootstrap suite, which signs with the wrong key on purpose.
# shellcheck disable=SC2034
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

# write_bootstrap <signing-key>: the two files served from the ROOT of the
# archive, which is where the install line fetches from. The package is a COPY
# of the pool object, byte for byte, the way publish.yml copies it: that is what
# lets the signed index pin the root copy without declaring it.
write_bootstrap() {
	cp "$SITE/$KEYRING_DEB" "$SITE/glyndor-archive-keyring.deb"
	gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
		--local-user "$1" --armor --detach-sign \
		--output "$SITE/glyndor-archive-keyring.deb.asc" \
		"$SITE/glyndor-archive-keyring.deb"
}

# build_archive: a consistent archive, signed with the trusted key.
build_archive() { build_archive_signed_by "$TRUSTED_KEY"; }

# build_archive_signed_by <signing-key>: a consistent archive, from scratch,
# signed by that key.
build_archive_signed_by() {
	local key="$1"
	rm -rf "$SITE"
	mkdir -p "$DIST"
	write_indices
	write_release "$key"
	write_bootstrap "$key"
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
