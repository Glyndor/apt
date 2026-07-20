#!/usr/bin/env bash
#
# Tests for scripts/build-keyring.sh.
#
# The one that matters is reproducibility. The package's version encodes the
# date the signing key changed, so its pool filename is stable across rebuilds
# while its bytes were not — and publish.yml syncs pool/ with --size-only and
# serves it immutable for a year. A rebuild that landed on the same size was
# therefore never uploaded, while reprepro had already written the NEW hash into
# the signed index, so the archive served a package its own index rejected.
# Locking determinism here is what stops that returning silently.
#
# The build reads git history to derive its version, so the cases below run
# against a throwaway repository built here rather than against this checkout.
# That keeps the suite hermetic — CI clones shallow (fetch-depth defaults to 1),
# and a test that only passes on a full clone is a test that fails for a reason
# having nothing to do with the code.
#
# Requires: gpg, dpkg-deb, git.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
BUILD="$REPO/scripts/build-keyring.sh"
mkdir -p "$REPO/scripts" "$REPO/keyring"
cp "$HERE/scripts/build-keyring.sh" "$REPO/scripts/"
cp "$HERE"/keyring/glyndor-apt-key.asc "$HERE"/keyring/glyndor.sources \
	"$HERE"/keyring/version "$REPO/keyring/"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid \
	commit -qm "fixture"

pass=0
fail=0

ok() {
	echo "ok   - $1"
	pass=$((pass + 1))
}

no() {
	echo "FAIL - $1"
	fail=$((fail + 1))
}

# --- Reproducibility ---------------------------------------------------------

mkdir -p "$WORK/first" "$WORK/second"
"$BUILD" "$WORK/first" >/dev/null
# Build the second one a moment later, so a build that stamps the clock rather
# than the inputs is guaranteed to differ rather than merely likely to.
sleep 2
"$BUILD" "$WORK/second" >/dev/null

first="$WORK/first/glyndor-archive-keyring.deb"
second="$WORK/second/glyndor-archive-keyring.deb"

if [ "$(stat -c%s "$first")" = "$(stat -c%s "$second")" ]; then
	ok "two builds of the same checkout are the same size"
else
	no "two builds of the same checkout are the same size ($(stat -c%s "$first") vs $(stat -c%s "$second"))"
fi

if cmp -s "$first" "$second"; then
	ok "two builds of the same checkout are byte-identical"
else
	no "two builds of the same checkout are byte-identical ($(sha256sum "$first" | cut -d' ' -f1) vs $(sha256sum "$second" | cut -d' ' -f1))"
fi

# --- The package is still a valid keyring package ----------------------------
# Reproducibility is worthless if it was achieved by building the wrong thing.

control="$(dpkg-deb --field "$first")"
if printf '%s' "$control" | grep -q '^Package: glyndor-archive-keyring$'; then
	ok "the built package declares the reserved keyring name"
else
	no "the built package declares the reserved keyring name"
fi

if printf '%s' "$control" | grep -qE '^Version: .+\+key[0-9]{14}$'; then
	ok "the version carries the signing key's change date"
else
	no "the version carries the signing key's change date"
fi

contents="$(dpkg-deb --contents "$first")"
for path in ./usr/share/keyrings/glyndor.gpg ./etc/apt/sources.list.d/glyndor.sources; do
	if printf '%s' "$contents" | grep -qF " $path"; then
		ok "the package ships $path"
	else
		no "the package ships $path"
	fi
done

# --- Fails closed without history --------------------------------------------
# The version must never silently fall back to one that does not bump on a key
# rotation: apt would then never deliver the renewal, which is the single
# guarantee this package exists to provide.

detached="$WORK/detached"
mkdir -p "$detached/scripts" "$detached/keyring" "$detached/out"
cp "$BUILD" "$detached/scripts/"
cp "$REPO"/keyring/glyndor-apt-key.asc "$REPO"/keyring/glyndor.sources \
	"$REPO"/keyring/version "$detached/keyring/"

got=0
out="$("$detached/scripts/build-keyring.sh" "$detached/out" 2>&1)" || got=$?
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF "no git history"; then
	ok "a build outside a git checkout fails closed"
else
	no "a build outside a git checkout fails closed (exit $got)"
fi

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
