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

if printf '%s' "$control" | grep -qE '^Version: .+\+pkg[0-9]{14}$'; then
	ok "the version carries the packaged inputs' change date"
else
	no "the version carries the packaged inputs' change date"
fi

# --- The version tracks every packaged input ---------------------------------
# Tracking only the key meant a change to the sources list reached clients'
# machines only if someone also remembered to bump keyring/version by hand.
# When they forgot, apt saw a version it already had and never delivered the
# new configuration — and nothing caught it, because the published archive
# stays perfectly self-consistent while being wrong.

before_version="$(dpkg-deb --field "$first" Version)"

bump_input() {
	local path="$1" line="$2" out="$3"
	printf '%s\n' "$line" >> "$REPO/$path"
	git -C "$REPO" add -A
	# A distinct, later commit date, so the suffix must move if the input is
	# tracked at all. Fixed rather than "now" so the case cannot race the clock.
	git -C "$REPO" -c user.name=test -c user.email=test@example.invalid \
		-c "commit.gpgsign=false" \
		commit -qm "touch $path" --date="2030-01-02T03:04:05+00:00"
	GIT_COMMITTER_DATE="2030-01-02T03:04:05+00:00" \
		git -C "$REPO" -c user.name=test -c user.email=test@example.invalid \
		commit -q --amend --no-edit --date="2030-01-02T03:04:05+00:00"
	mkdir -p "$WORK/$out"
	"$BUILD" "$WORK/$out" >/dev/null
	dpkg-deb --field "$WORK/$out/glyndor-archive-keyring.deb" Version
}

after_sources="$(bump_input keyring/glyndor.sources "# tracked-input probe" sources-bump)"
if [ "$after_sources" != "$before_version" ]; then
	ok "editing the sources list moves the version ($before_version -> $after_sources)"
else
	no "editing the sources list moves the version (stayed $before_version)"
fi

# apt refuses to move a client backwards, so a version that changes but does not
# INCREASE is as undeliverable as one that never moved.
if dpkg --compare-versions "$after_sources" gt "$before_version"; then
	ok "the new version sorts strictly above the old one"
else
	no "the new version sorts strictly above the old one ($before_version -> $after_sources)"
fi

# The suffix was renamed from +key to +pkg once it stopped tracking only the
# key. A rename that sorted below what is already published would strand every
# installed client on a version apt would refuse to upgrade.
if dpkg --compare-versions "1.0.0+pkg20260614003800" gt "1.0.0+key20260613233717"; then
	ok "the +pkg suffix sorts above the +key versions already published"
else
	no "the +pkg suffix sorts above the +key versions already published"
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
