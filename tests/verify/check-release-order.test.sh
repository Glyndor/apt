#!/usr/bin/env bash
# Exercise the public CLI with real curl/GPG and signed synthetic archives.
# Every case is rerun with its defence changed in a disposable script copy;
# the original expectation must then fail, with the diff and failure printed.
set -euo pipefail
pass=0; fail=0
# shellcheck source=tests/fixtures/verify/release-order/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/../fixtures/verify/release-order/harness.sh"

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

snapshot order
TAG=v1.0.0
case_with_control 'Version ahead of Package still reaches the product' 1 'refusing to publish' order
snapshot twice
TAG=v5.0.0
case_with_control 'a stanza with two Versions is refused' 1 'exactly once' once
snapshot package-twice
TAG=v5.0.0
case_with_control 'a stanza naming its Package twice is refused' 1 'names its Package more than once' pkgtwice
snapshot arch-gap
TAG=v2.5.0
case_with_control 'a declared architecture with no Packages file is refused' 1 'lists no Packages file' arch

# --- an index the signature covers and the reader cannot use is a refusal --------------------
# Each one is signed with a key of its own, so the signature verifies and the refusal that fires is
# the one about the content, which `check` tells apart by its message.
ACTIVE="$VERIFY"
snapshot no-sha256-section
TAG=v2.0.0
check 1 'declares no SHA256 section' 'a signed index with no SHA256 section is refused'
snapshot no-packages-file
check 1 'declares no per-architecture Packages file' 'a signed index whose SHA256 section lists no Packages file is refused'
snapshot served-version-not-semver
check 1 "the served version '1.0' of podup cannot be compared" 'a served version dpkg accepts and SemVer does not is refused'
check 1 'could not compare podup 2.0.0 against the version the archive serves' 'and the script says which comparison it could not make'
snapshot new
check 0 'is not older' 'the same checks over an index with a SHA256 section and a SemVer version pass'

# --- a tool that cannot run, or is not there, is a refusal ----------------------------------
# dpkg-deb is found on PATH and then fails to start (its interpreter does not exist) or prints
# what is not text, and is then left off PATH altogether. The script runs with a PATH of its own that
# holds what it needs and nothing else, because a failing command placed before the real one is
# skipped by the program that looks it up. The case with a working dpkg-deb in that PATH has to
# pass: that is what shows it is whole and that the refusal is the tool.
sandbox() { # <directory> [<command>]: the tools the script needs, and the command at its path in <directory>
	local dir="$1" tool
	mkdir -p "$dir"
	for tool in bash tar gpg curl gpgv gpgconf python3 sha256sum cut stat mktemp chmod rm timeout sed dirname dpkg; do
		ln -sf "$(command -v "$tool")" "$dir/$tool"
	done
	[ -z "${2:-}" ] || ln -sf "$2" "$dir/${2##*/}"
}
mkdir -p "$WORK/stub-cannot-start" "$WORK/stub-not-text"
printf '%s\n' '#!/nonexistent/interpreter' > "$WORK/stub-cannot-start/dpkg-deb"
printf '%s\n' '#!/usr/bin/env bash' "printf '\\377\\376'" > "$WORK/stub-not-text/dpkg-deb"
chmod 755 "$WORK/stub-cannot-start/dpkg-deb" "$WORK/stub-not-text/dpkg-deb"
sandbox "$WORK/whole" "$(command -v dpkg-deb)"
sandbox "$WORK/no-deb"
sandbox "$WORK/cannot-start" "$WORK/stub-cannot-start/dpkg-deb"
sandbox "$WORK/not-text" "$WORK/stub-not-text/dpkg-deb"
sandbox "$WORK/no-dpkg" "$(command -v dpkg-deb)"
rm "$WORK/no-dpkg/dpkg"
snapshot old
TAG=v1.0.0
SCRIPT_PATH="$WORK/whole" check 0 'is not older' 'a PATH with every tool the script needs passes'
SCRIPT_PATH="$WORK/cannot-start" check 1 'cannot run dpkg-deb' 'a dpkg-deb that cannot start refuses the publish'
SCRIPT_PATH="$WORK/not-text" check 1 'cannot run dpkg-deb' 'a dpkg-deb that prints what is not text refuses the publish'
SCRIPT_PATH="$WORK/no-deb" check 1 'dpkg-deb is required' 'a PATH without dpkg-deb refuses the publish'
SCRIPT_PATH="$WORK/no-dpkg" check 1 'dpkg is required' 'a PATH without dpkg refuses the publish'

# --- a dpkg that cannot answer is a refusal, not a pass -------------------------
# dpkg exits 2 when it cannot validate or compare a version. Reading that as "not older" would let
# a rollback through, so each failure has to end the publish with its own message. The stub
# delegates everything else to the real dpkg, so only the call under test fails.
REAL_DPKG="$(command -v dpkg)"
export REAL_DPKG
cat > "$WORK/bin/dpkg" <<'SH'
#!/usr/bin/env bash
case "${FAKE_DPKG_FAIL:-}:${1:-}" in
	validate:--validate-version | compare:--compare-versions) exit 2 ;;
esac
exec "$REAL_DPKG" "$@"
SH
chmod 755 "$WORK/bin/dpkg"
snapshot old
TAG=v1.0.0
FAKE_DPKG_FAIL=validate check 1 'cannot be compared' 'a dpkg that cannot validate the candidate version refuses the publish'
FAKE_DPKG_FAIL=compare check 1 'dpkg could not compare' 'a dpkg that cannot compare the candidate refuses the publish'
check 0 'is not older' 'the same archive with a working dpkg is accepted'

# --- the full Debian version, not only the release the tag names -------------
# The tag advances while the package goes back: the epoch or the revision is
# dropped, and apt would treat the candidate as a downgrade.
snapshot epoch
TAG=v5.17.0
CAND=5.17.0 case_with_control 'a candidate without the served epoch is refused' 1 'in Debian version order' debian
CAND=2:5.17.0-1 case_with_control 'a candidate that keeps the epoch and advances passes' 0 'is not older' debian_pass
snapshot revision
TAG=v5.16.0
CAND=5.16.0 case_with_control 'a candidate with a lower revision is refused' 1 'in Debian version order' debian
CAND=5.16.0-2 case_with_control 'a candidate with a higher revision passes' 0 'is not older' debian_pass
TAG=v5.17.0
CAND=NONE case_with_control 'no candidate .deb is refused' 1 'no candidate .deb files' nodebs
CAND_PACKAGE=other case_with_control 'a candidate that is another package is refused' 1 'cannot read candidate Package/Version' package

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
snapshot new
# A served Packages of 9 MiB against the 8 MiB cap, with a size that matches no
# signed one: the cap has to stop the transfer before the size comparison can
# name a mismatch, so the message is the one the fetch writes.
python3 -I -c 'open("'"$DIST"'/main/binary-amd64/Packages", "wb").write(b"x" * (9 * 1024 * 1024))'
case_with_control 'served Packages over the 8 MiB cap fails at the fetch' 1 'could not fetch the served index file' index-cap
snapshot near-cap
case_with_control 'valid signed InRelease just under cap passes' 0 'is not older' lower-cap
snapshot new
TAG=not-semver
CAND=99:1.0.0
case_with_control 'non-SemVer tag fails comparison' 1 'not a valid SemVer' semver

# The key that anchors the signature of the index has to exist and to import before the order is judged: the guard that
# stops a rollback reads the served index through it, and one that went on without it would read an unsigned answer.
snapshot old
PRODUCT=podup
TAG=v3.0.0
ACTIVE="$VERIFY"
KEY="$WORK/absent.asc"
check 1 "archive public key $WORK/absent.asc not found" "a public key file that is not there is refused"
printf 'this is not a key\n' > "$WORK/not-a-key.asc"
KEY="$WORK/not-a-key.asc"
check 1 "could not import the archive public key from $WORK/not-a-key.asc" "a public key file that is not a key is refused"

# --- the served index is judged before it is compared with ------------------------------------
snapshot new
PRODUCT=podup
TAG=v3.0.0
ACTIVE="$VERIFY"
rm -f "$WORK/baseline.calls"
check 0 'is not older' 'an index the baseline accepts is compared with'
if [ "$(sed -n 3p "$WORK/baseline.calls")" = "-----BEGIN PGP SIGNED MESSAGE-----" ] \
	&& [ "$(sed -n 2p "$WORK/baseline.calls")" = "$(sha256sum "$DIST/InRelease" | cut -d' ' -f1)" ] \
	&& [ "$(sed -n 1p "$WORK/baseline.calls")" != "$(sed -n 2p "$WORK/baseline.calls")" ]; then
	echo "ok   - the baseline is handed the verified body and the InRelease that was served"
	pass=$((pass + 1))
else
	echo "FAIL - the baseline was not handed the verified body and the served InRelease"
	fail=$((fail + 1))
fi
BASELINE_EXIT=1 check 1 'cannot be taken as the baseline of podup v3.0.0' 'an index the baseline refuses stops the publish'
rm -f "$WORK/baseline.calls"
sed -i 's/Origin: Glyndor/Origin: Altered/' "$DIST/InRelease"
check 1 'does not verify against' 'an index that does not verify is refused by the signature'
if [ ! -e "$WORK/baseline.calls" ]; then
	echo "ok   - and the baseline is not asked about it"
	pass=$((pass + 1))
else
	echo "FAIL - the baseline judged an index that did not verify"
	fail=$((fail + 1))
fi
# The script beside the real baseline, which judges the same fixture and finds no Valid-Until in it.
snapshot new
cp "$HERE/scripts/verify/check-index-baseline.sh" "$COPY/check-index-baseline.sh"
echo none > "$WORK/record"
printf 'none\n' > "$COPY/index-floor.txt"
INDEX_RECORD="$WORK/record" check 1 'does not declare Valid-Until exactly once' 'the baseline that ships is the one the script calls'

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
