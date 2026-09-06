#!/usr/bin/env bash
#
# Tests for scripts/build-keyring.sh.
#
# The one that matters is reproducibility. The package's version encodes the
# date the signing key changed, so its pool filename is stable across rebuilds
# while its bytes were not, and publish.yml syncs pool/ with --size-only and
# serves it immutable for a year. A rebuild that landed on the same size was
# therefore never uploaded, while reprepro had already written the NEW hash into
# the signed index, so the archive served a package its own index rejected.
# Locking determinism here is what stops that returning silently.
#
# The build reads git history to derive its version, so the cases below run
# against a throwaway repository built here rather than against this checkout.
# That keeps the suite hermetic: CI clones shallow (fetch-depth defaults to 1),
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
	"$HERE"/keyring/glyndor-unattended-upgrades \
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
# new configuration, and nothing caught it, because the published archive
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

# Same guarantee for the unattended-upgrades allowlist. Shipping a changed
# allowlist under a version apt has already installed means apt never offers it,
# so the file would be correct in the archive and absent on every machine.
after_unattended="$(bump_input keyring/glyndor-unattended-upgrades "// tracked-input probe" unattended-bump)"
if [ "$after_unattended" != "$before_version" ]; then
	ok "editing the unattended-upgrades config moves the version ($before_version -> $after_unattended)"
else
	no "editing the unattended-upgrades config moves the version (stayed $before_version)"
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
for path in ./usr/share/keyrings/glyndor.gpg ./etc/apt/sources.list.d/glyndor.sources \
	./etc/apt/apt.conf.d/51glyndor-unattended-upgrades; do
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
# Every packaged input, not just the ones this case is about: the build fails
# closed on a missing one, and a fixture short of a file would fail here for
# that reason instead of the missing history this case exists to check.
cp "$REPO"/keyring/glyndor-apt-key.asc "$REPO"/keyring/glyndor.sources \
	"$REPO"/keyring/glyndor-unattended-upgrades \
	"$REPO"/keyring/version "$detached/keyring/"

got=0
out="$("$detached/scripts/build-keyring.sh" "$detached/out" 2>&1)" || got=$?
if [ "$got" -ne 0 ] && printf '%s' "$out" | grep -qF "no git history"; then
	ok "a build outside a git checkout fails closed"
else
	no "a build outside a git checkout fails closed (exit $got)"
fi

# --- a key clients cannot use must not be packaged --------------------------
#
# Counting keys is not the same as having a usable one: an expired or revoked
# key dearmors and counts exactly like a live one. A client that installed it
# would reject every Release signature this archive produces, and the breakage
# would read as "the archive is broken" rather than "the key is expired",
# because nothing in the publish log mentioned expiry.

key_repo() { # $1=dir $2=gpg lifetime spec
	local dir="$1" life="$2"
	rm -rf "$dir"; mkdir -p "$dir/scripts" "$dir/keyring"
	cp "$HERE/scripts/build-keyring.sh" "$dir/scripts/"
	cp "$HERE"/keyring/glyndor.sources "$HERE"/keyring/glyndor-unattended-upgrades \
		"$HERE"/keyring/version "$dir/keyring/"
	local home="$dir/.gnupg"; mkdir -p "$home"; chmod 700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "fixture <f@test.invalid>" default default "$life" \
		>/dev/null 2>&1
	GNUPGHOME="$home" gpg --batch --armor --export fixture \
		> "$dir/keyring/glyndor-apt-key.asc"
	GNUPGHOME="$home" gpgconf --kill all >/dev/null 2>&1 || true
	git -C "$dir" init -q
	git -C "$dir" add -A
	git -C "$dir" -c user.name=test -c user.email=test@example.invalid \
		commit -qm fixture
}

# The acceptance half first. Without it the refusal below is satisfied by a
# script that refuses every generated key, and the case would prove nothing.
key_repo "$WORK/live" "never"
rc=0
out="$("$WORK/live/scripts/build-keyring.sh" "$WORK/out-live" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "a key with no expiry is packaged"
else
	no "a key with no expiry is packaged (exit $rc: $out)"
fi

# `seconds=1` plus a wait, rather than a date in the past: gpg refuses to create
# a key that is already expired.
key_repo "$WORK/exp" "seconds=1"
sleep 2
rc=0
out="$("$WORK/exp/scripts/build-keyring.sh" "$WORK/out-exp" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
	ok "an expired key is refused"
else
	no "an expired key is refused (exited 0)"
fi
if printf '%s' "$out" | grep -q 'clients cannot use'; then
	ok "and the error says clients could not use it"
else
	no "and the error says clients could not use it (got: $out)"
fi
if printf '%s' "$out" | grep -q 'expired:'; then
	ok "and says which way it is unusable"
else
	no "and says which way it is unusable (got: $out)"
fi
if [ ! -f "$WORK/out-exp/glyndor-archive-keyring.deb" ]; then
	ok "and no package was written"
else
	no "and no package was written"
fi

# Live today, expiring soon: a warning, not a refusal. The archive publishes
# daily, so the log is read long before the expiry lands.
key_repo "$WORK/soon" "7d"
rc=0
out="$("$WORK/soon/scripts/build-keyring.sh" "$WORK/out-soon" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "a key expiring soon is still packaged"
else
	no "a key expiring soon is still packaged (exit $rc: $out)"
fi
if printf '%s' "$out" | grep -q 'expires in'; then
	ok "and the run warns how long is left"
else
	no "and the run warns how long is left (got: $out)"
fi

# --- Result ------------------------------------------------------------------

echo
# --- A keyring with no public key is refused, not packaged --------------------
# `gpg --dearmor` accepts any armoured packet, and a file that dearmors cleanly
# but carries no public key (a detached signature block is the smallest such
# file) reaches the packaging step with nothing in it. Packaged, it installs
# cleanly, verifies nothing, and every fresh install refuses it on the
# fingerprint check. The build must stop here; the line existed in the script
# and not as a test. A zero-byte file is not the fixture: dearmor refuses that
# on its own before the check is reached.

NOKEY="$WORK/nokey"
cp -r "$REPO" "$NOKEY"
export GNUPGHOME="$WORK/gnupg-nokey"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-generate-key 'nokey <nokey@example.invalid>' ed25519 sign never 2>/dev/null
printf 'payload\n' > "$WORK/payload"
rm -f "$NOKEY/keyring/glyndor-apt-key.asc"
gpg --batch --quiet --armor --detach-sign --output "$NOKEY/keyring/glyndor-apt-key.asc" "$WORK/payload"
unset GNUPGHOME
git -C "$NOKEY" add -A
git -C "$NOKEY" -c user.name=test -c user.email=test@example.invalid commit -qm "no key"
mkdir -p "$WORK/nokey-out"
if out="$("$NOKEY/scripts/build-keyring.sh" "$WORK/nokey-out" 2>&1)"; then
	no "an armoured file carrying no public key refuses to build"
else
	ok "an armoured file carrying no public key refuses to build"
fi
if printf '%s' "$out" | grep -q 'keyring contains no usable key'; then
	ok "and it is refused for the missing key, not something else"
else
	no "and it is refused for the missing key, not something else ($(printf '%s' "$out" | tail -n 1))"
fi
if [ ! -e "$WORK/nokey-out/glyndor-archive-keyring.deb" ]; then
	ok "and no package was written"
else
	no "and no package was written"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
