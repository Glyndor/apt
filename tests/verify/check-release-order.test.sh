#!/usr/bin/env bash
# Exercise the public CLI with real curl/GPG and signed synthetic archives.
# Every case is rerun with its defence changed in a disposable script copy;
# the original expectation must then fail, with the diff and failure printed.
set -euo pipefail
pass=0; fail=0
# shellcheck source=tests/verify/fixtures/release-order/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/release-order/harness.sh"

PRODUCT=podup
TAG=v3.0.0
case_with_control 'higher tag passes' 0 'is not older' greater
TAG=v2.0.0
case_with_control 'equal tag passes' 0 'is not older' equal
TAG=v1.0.0
case_with_control 'lower tag refuses publication' 1 'refusing to publish' comparison
TAG=v2.0.0-rc.1
case_with_control 'prerelease is below its release' 1 'refusing to publish' prerelease
PRODUCT=absent-product
TAG=v1.0.0
case_with_control 'unserved product is first publication' 0 'first publication' first
PRODUCT=podup

snapshot old
TAG=v1.0.0
case_with_control 'old signed fixture also verifies' 0 'is not older' equal
snapshot revision
TAG=v5.16.0
case_with_control 'Debian 5.16.0-1 is release 5.16.0' 0 'is not older' equal
TAG=v5.16.0-rc.1
case_with_control 'revision normalizes before prerelease comparison' 1 'refusing to publish' revision
TAG=v5.15.0
case_with_control 'Debian revision still prevents rollback' 1 'refusing to publish' comparison
snapshot epoch
TAG=v5.16.0
case_with_control 'Debian epoch is not release precedence' 0 'is not older' epoch
TAG=v5.15.0
case_with_control 'epoch still prevents upstream rollback' 1 'refusing to publish' comparison
snapshot multi
TAG=v1.5.0
case_with_control 'two architectures use highest version' 1 'refusing to publish' highest
TAG=v2.0.0
case_with_control 'equal highest architecture passes' 0 'is not older' equal
snapshot description
TAG=v1.0.0
case_with_control 'indented Package in description cannot hide product' 1 'refusing to publish' description
TAG=v2.0.0
case_with_control 'description archive accepts equal release' 0 'is not older' equal

snapshot new
TAG=v3.0.0
case_with_control 'trusted signature positive control' 0 'is not older' greater
# This snapshot is signed by the *other* fixture key: valid, but untrusted.
snapshot revision
KEY="$FIXTURES/archive-key.asc"
TAG=v6.0.0
case_with_control 'signature from another key fails closed' 1 'does not verify against' gpgv

snapshot new
TAG=v3.0.0
sed -i 's/Origin: Glyndor/Origin: Altered/' "$DIST/InRelease"
case_with_control 'InRelease changed after signing fails closed' 1 'does not verify against' gpgv

snapshot new
printf '\n' >> "$DIST/main/binary-amd64/Packages"
case_with_control 'Packages size differs from signed size' 1 'signed index declares 357' size
snapshot new
# Same length, different digest: reaches SHA256 rather than the size guard.
sed -i 's/Version: 2.0.0/Version: 1.0.0/' "$DIST/main/binary-amd64/Packages"
case_with_control 'Packages SHA256 differs at same size' 1 'does not match the SHA256' sha256

snapshot new
mv "$DIST/InRelease" "$WORK/hidden-InRelease"
case_with_control 'missing InRelease (HTTP 404) fails closed' 1 'could not fetch the served index' fetch
snapshot oversized
TAG=v3.0.0
case_with_control 'valid signed InRelease over 1 MiB cap fails' 1 'could not fetch the served index' cap
snapshot near-cap
case_with_control 'valid signed InRelease just under cap passes' 0 'is not older' lower-cap
snapshot new
TAG=not-semver
case_with_control 'non-SemVer tag fails comparison' 1 'not a valid SemVer' semver

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
