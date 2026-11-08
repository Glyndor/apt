#!/usr/bin/env bash
# APT-11: exercise the signed artifact, not the ValidFor source line.
# Removing ValidFor from build-repo.sh must fail the interval assertion and
# must stop the expired replica from being rejected by apt for expiry.
# Requires real reprepro, gpg, gpgv, dpkg-deb, apt-get and python3; no root/network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
export GNUPGHOME="$WORK/gnupg" LC_ALL=C
mkdir -m 700 "$GNUPGHOME"
pass=0
fail=0
cleanup() {
	timeout 10 gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo "FAIL  prerequisite or fixture setup failed; archive expiry SIN VERIFICAR"; \
	printf "DONE %s %d %d\n" "${BASH_SOURCE[0]##*/}" "$pass" "$((fail + 1))"' ERR

check() {
	local description="$1"; shift
	if "$@"; then
		echo "ok    $description"; pass=$((pass + 1))
	else
		echo "FAIL  $description"; fail=$((fail + 1))
	fi
}

for tool in reprepro gpg gpgv gpgconf dpkg-deb apt-get apt-cache python3; do
	command -v "$tool" >/dev/null || { echo "missing prerequisite: $tool"; false; }
done

gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key 'APT expiry test <expiry@test.invalid>' rsa3072 sign 0
mkdir -p "$WORK/root/scripts/build" "$WORK/root/keyring" "$WORK/pkg/DEBIAN"
cp "$HERE/scripts/build/build-repo.sh" "$HERE/scripts/build/build-index-page.sh" "$WORK/root/scripts/build/"
gpg --batch --armor --export > "$WORK/root/keyring/glyndor-apt-key.asc"
gpg --batch --export > "$WORK/archive-key.gpg"
gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys > "$WORK/secret.asc"
cat > "$WORK/pkg/DEBIAN/control" <<'EOF'
Package: expiry-fixture
Version: 1.0
Architecture: amd64
Section: utils
Priority: optional
Maintainer: Test <expiry@test.invalid>
Description: archive expiry fixture
EOF
dpkg-deb --root-owner-group --build "$WORK/pkg" "$WORK/fixture.deb" >/dev/null
GLYNDOR_APT_GPG_PRIVATE_KEY="$(cat "$WORK/secret.asc")" \
	"$WORK/root/scripts/build/build-repo.sh" "$WORK/fresh" "$WORK/fixture.deb"

verify_signed_release() {
	local dist="$1/dists/stable"
	gpgv --keyring "$WORK/archive-key.gpg" "$dist/Release.gpg" "$dist/Release" &&
		gpgv --keyring "$WORK/archive-key.gpg" --output - "$dist/InRelease" > "$WORK/verified-release" &&
		cmp "$WORK/verified-release" "$dist/Release"
}
check "the real reprepro Release and InRelease verify and carry the same content" \
	verify_signed_release "$WORK/fresh"
check "the signed Valid-Until is 14 days after Date (within 60 seconds)" \
	python3 - "$WORK/fresh/dists/stable/Release" <<'PY'
import email.utils
import pathlib
import sys

fields = dict(line.split(': ', 1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if ': ' in line)
try:
    start, end = (email.utils.parsedate_to_datetime(fields[name]).timestamp() for name in ('Date', 'Valid-Until'))
except (KeyError, ValueError, TypeError) as exc:
    sys.exit(f'missing or invalid signed expiry: {exc}')
print(f'Date={fields["Date"]}; Valid-Until={fields["Valid-Until"]}; interval={end-start:.0f}s')
if abs(end - start - 1209600) > 60:
    sys.exit('expected a signed validity window of approximately 1209600 seconds')
PY

# Shift BOTH dates back 15 days, preserving the actual production window.
# If ValidFor is removed, do not invent a Valid-Until: apt must expose that
# regression by accepting the stale replica, and the interval check fails too.
cp -a "$WORK/fresh" "$WORK/expired"
python3 - "$WORK/expired/dists/stable/Release" <<'PY'
import datetime
import email.utils
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = []
for line in path.read_text().splitlines():
    if line.startswith(('Date: ', 'Valid-Until: ')):
        name, value = line.split(': ', 1)
        shifted = email.utils.parsedate_to_datetime(value) - datetime.timedelta(days=15)
        line = f'{name}: {email.utils.format_datetime(shifted)}'
    lines.append(line)
path.write_text('\n'.join(lines) + '\n')
PY
gpg --batch --yes --pinentry-mode loopback --passphrase '' --armor \
	--detach-sign --output "$WORK/expired/dists/stable/Release.gpg" "$WORK/expired/dists/stable/Release"
gpg --batch --yes --pinentry-mode loopback --passphrase '' \
	--clearsign --output "$WORK/expired/dists/stable/InRelease" "$WORK/expired/dists/stable/Release"
check "the expired replica still has valid signatures" verify_signed_release "$WORK/expired"

# Each update has its own configuration, lists, cache, status and logs. Read
# no host sources, trusted keys or apt.conf.d hooks; install nothing. APT_CONFIG
# is loaded before apt.conf.d, so these paths also isolate the initial load.
apt_update() {
	local kind="$1" state="$WORK/apt-$1"
	mkdir -p "$state/etc/parts" "$state/etc/sources.list.d" "$state/etc/trusted.gpg.d" "$state/etc/preferences.d" \
		"$state/state/lists/partial" "$state/cache/archives/partial" "$state/log"
	: > "$state/state/status"
	printf 'deb [arch=amd64 signed-by=%s] file:%s stable main\n' \
		"$WORK/archive-key.gpg" "$WORK/$kind" > "$state/etc/sources.list"
	cat > "$state/config" <<EOF
Dir "$state";
Dir::Etc "$state/etc";
Dir::Etc::parts "$state/etc/parts";
Dir::Etc::main "$state/etc/apt.conf";
Dir::Etc::trusted "$state/etc/trusted.gpg";
Dir::Etc::trustedparts "$state/etc/trusted.gpg.d";
Dir::State "$state/state";
Dir::State::status "$state/state/status";
Dir::Cache "$state/cache";
Dir::Log "$state/log";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
APT::Sandbox::User "$(id -un)";
APT::Update::Error-Mode "any";
Acquire::Languages "none";
Acquire::Check-Date "true";
Acquire::Check-Valid-Until "true";
Acquire::AllowInsecureRepositories "false";
Acquire::AllowDowngradeToInsecureRepositories "false";
EOF
	APT_CONFIG="$state/config" apt-get update > "$WORK/apt-$kind.log" 2>&1
}

fresh_rc=0; apt_update fresh || fresh_rc=$?
expired_rc=0; apt_update expired || expired_rc=$?
cat "$WORK/apt-fresh.log" "$WORK/apt-expired.log"
check "isolated apt admits the current signed archive" test "$fresh_rc" -eq 0
# Require a candidate from the fetched index, not an empty successful update.
check "the admitted index offers the real fixture package" grep -q 'Candidate: 1.0$' \
	<<< "$(APT_CONFIG="$WORK/apt-fresh/config" apt-cache policy expiry-fixture)"
check "isolated apt refuses the expired replica" test "$expired_rc" -eq 100
check "the refusal specifically names expiry" grep -q 'Release file .* is expired' "$WORK/apt-expired.log"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
trap - ERR
[ "$fail" -eq 0 ]
