#!/usr/bin/env bash
#
# scripts/build/add-by-hash.sh copies every index file the Release declares to
# its by-hash name, adds `Acquire-By-Hash: yes` to the Release and signs it. The
# copies and the field are what keeps `apt update` from failing with "Hash Sum
# mismatch" while a publish replaces the index, and a client trusts the field
# only because it is inside the signature, so each refusal here is one that
# stops a wrong index from being signed.
#
# The distribution is built by tests/fixtures/build/unsigned-dist.sh in the
# shape reprepro exports it (the fields, the three checksum lists, the
# per-architecture Release), so the script runs without reprepro. tests/build/build-repo-expiry.test.sh runs it
# behind a real reprepro export where reprepro is installed, and
# tests/build/add-by-hash/add-by-hash-apt.test.sh shows an apt client using the
# copies.
#
# Every refusal is asserted by its message and paired with an acceptance of the
# same shape.
#
# Requires: gpg, gpgv, gzip, sha256sum, md5sum, sha1sum.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/build/add-by-hash.sh"
WORK="$(mktemp -d)"
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
trap 'timeout 10 gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true; rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

for tool in gpg gpgv gzip sha256sum md5sum sha1sum; do
	command -v "$tool" >/dev/null 2>&1 || { echo "NOTE  $tool is missing, so nothing below could run. Not a pass."; exit 1; }
done

gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key 'by-hash test <by-hash@test.invalid>' ed25519 sign never >/dev/null 2>&1
FPR="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
gpg --batch --armor --export "$FPR" > "$WORK/archive-key.asc" 2>/dev/null
# A second key, which the archive does not trust, for the signature check.
OTHER="$WORK/other-gnupg"
mkdir -m 700 "$OTHER"
GNUPGHOME="$OTHER" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key 'stranger <stranger@test.invalid>' ed25519 sign never >/dev/null 2>&1
GNUPGHOME="$OTHER" gpg --batch --armor --export > "$WORK/other-key.asc" 2>/dev/null

# shellcheck source=tests/fixtures/build/unsigned-dist.sh
. "$HERE/tests/fixtures/build/unsigned-dist.sh"

run() { # $1=root [$2=public key]
	bash "$SCRIPT" "$1/dists/stable" "$FPR" "${2:-$WORK/archive-key.asc}" > "$WORK/out" 2>&1
}
said() { grep -cF -- "$1" "$WORK/out"; }
fresh() { rm -rf "${WORK:?}/${1:?}"; mkdist "$WORK/$1"; echo "$WORK/$1"; }

# --- the control ---------------------------------------------------------------------
D="$(fresh good)"
cp "$D/dists/stable/Release" "$WORK/unsigned-release"
rc=0; run "$D" || rc=$?
check "a distribution as reprepro exports it is offered by hash and signed" "0" "$rc"
check "and it says how many index files it offered" "1" "$(said 'offered 6 index file(s) by hash')"
R="$D/dists/stable/Release"
check "the Release carries Acquire-By-Hash: yes once" "1" "$(grep -c '^Acquire-By-Hash: yes$' "$R")"
check "before the first checksum list" "1" \
	"$(awk '/^Acquire-By-Hash:/ { a = NR } /^MD5Sum:/ { m = NR } END { print (a && a + 1 == m) ? 1 : 0 }' "$R")"
check "and is otherwise the Release reprepro wrote" "" \
	"$(diff <(grep -v '^Acquire-By-Hash:' "$R") "$WORK/unsigned-release")"
gpg --batch --export "$FPR" > "$WORK/archive-key.gpg" 2>/dev/null
body_ok=0
gpgv --keyring "$WORK/archive-key.gpg" --quiet --output "$WORK/body" "$D/dists/stable/InRelease" 2>/dev/null \
	&& cmp -s "$WORK/body" "$R" && body_ok=1
check "InRelease verifies against the archive key and its body is the Release" "1" "$body_ok"
detached_ok=0
gpgv --keyring "$WORK/archive-key.gpg" --quiet "$D/dists/stable/Release.gpg" "$R" 2>/dev/null && detached_ok=1
check "Release.gpg verifies against the archive key" "1" "$detached_ok"
copies=0; same=0
while read -r sha _ path; do
	copy="$D/dists/stable/$(dirname "$path")/by-hash/SHA256/$sha"
	[ -f "$copy" ] && copies=$((copies + 1))
	cmp -s "$copy" "$D/dists/stable/$path" && same=$((same + 1))
done < <(awk '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f' "$R")
check "every file of the SHA256 list has its by-hash copy" "6" "$copies"
check "holding the bytes of the file it is named for" "6" "$same"
check "and nothing else is under by-hash" "6" "$(find "$D/dists/stable" -path '*/by-hash/SHA256/*' -type f | wc -l)"

# A field already there is accepted only as the line this script writes.
D="$(fresh present)"
sed -i 's/^MD5Sum:$/Acquire-By-Hash: yes\nMD5Sum:/' "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "a Release that already says Acquire-By-Hash: yes is signed as it is" "0" "$rc"
check "without a second line" "1" "$(grep -c '^Acquire-By-Hash:' "$D/dists/stable/Release")"
D="$(fresh other-value)"
sed -i 's/^MD5Sum:$/Acquire-By-Hash: no\nMD5Sum:/' "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "a Release that says Acquire-By-Hash: no is refused" "1" "$rc"
check "naming the field" "1" "$(said "already carries an Acquire-By-Hash field that is not")"
check "and nothing is signed" "0" "$(find "$D/dists/stable" -maxdepth 1 -name InRelease | wc -l)"

# --- what is copied is what the Release declares ----------------------------------------
D="$(fresh altered)"
printf 'Package: smuggled\n\n' >> "$D/dists/stable/main/binary-amd64/Packages"
rc=0; run "$D" || rc=$?
check "an index file whose bytes are not the declared ones is refused" "1" "$rc"
check "naming it" "1" "$(said 'main/binary-amd64/Packages is not the file')"
check "and nothing is signed" "0" "$(find "$D/dists/stable" -maxdepth 1 -name InRelease | wc -l)"
D="$(fresh same-size)"
sed -i 's/^Version: 1.0$/Version: 1.1/' "$D/dists/stable/main/binary-arm64/Packages"
rc=0; run "$D" || rc=$?
check "and so is one of the declared size with other bytes" "1" "$(said 'main/binary-arm64/Packages is not the file')"

D="$(fresh missing)"
rm "$D/dists/stable/main/binary-arm64/Packages.gz"
rc=0; run "$D" || rc=$?
check "a declared index file that is not there is refused" "1" "$rc"
check "naming it" "1" "$(said 'declares main/binary-arm64/Packages.gz, which is not in')"

D="$(fresh no-sha256)"
awk '/^SHA256:/ { skip = 1; next } /^[^ ]/ { skip = 0 } !skip' "$D/dists/stable/Release" > "$WORK/r" && mv "$WORK/r" "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "a Release with no SHA256 list is refused" "1" "$rc"
check "and says so" "1" "$(said 'declares no SHA256 entries')"

D="$(fresh climbing)"
sed -i '/^SHA256:$/a\ '"$(printf '%064d' 0)"' 1 ../../escape' "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "a declared path that climbs out of the distribution is refused" "1" "$rc"
check "naming it" "1" "$(said 'declares a path that is not a plain relative index path: ../../escape')"
D="$(fresh by-hash-path)"
sed -i '/^SHA256:$/a\ '"$(printf '%064d' 0)"' 1 main/binary-amd64/by-hash/SHA256/x' "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "and so is one that names a by-hash copy itself" "1" "$(said 'not a plain relative index path: main/binary-amd64/by-hash')"

D="$(fresh short-hash)"
sed -i '/^SHA256:$/a\ abc 1 main/binary-amd64/Packages' "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "a SHA256 line that is not a hash, a size and a path is refused" "1" "$rc"
check "and says so" "1" "$(said "has a SHA256 line that is not '<sha256> <size> <path>'")"

D="$(fresh sha512)"
sed -i 's/^SHA256:$/SHA512:/' "$D/dists/stable/Release"
rc=0; run "$D" || rc=$?
check "a Release whose only long list is not SHA256 has nothing to offer" "1" "$(said 'declares no SHA256 entries')"

# --- the signature is checked with the key clients have --------------------------------
D="$(fresh untrusted)"
rc=0; run "$D" "$WORK/other-key.asc" || rc=$?
check "an index signed by a key the given public key is not is refused" "1" "$rc"
check "naming the signature that does not verify" "1" "$(said 'the InRelease just signed does not verify against')"
check "and leaves no signed index behind" "0" "$(find "$D/dists/stable" -maxdepth 1 -name 'InRelease' -o -maxdepth 1 -name 'Release.gpg' | wc -l)"

D="$(fresh no-key)"
rc=0; run "$D" "$WORK/absent.asc" || rc=$?
check "a public key file that is not there is refused" "1" "$(said 'no public key at')"
rc=0; bash "$SCRIPT" "$WORK/nowhere/dists/stable" "$FPR" "$WORK/archive-key.asc" > "$WORK/out" 2>&1 || rc=$?
check "a distribution with no Release is refused" "1" "$(said 'no Release at')"
rc=0; bash "$SCRIPT" "$D/dists/stable" > "$WORK/out" 2>&1 || rc=$?
check "and a call without its arguments says how to call it" "2" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
