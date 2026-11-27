#!/usr/bin/env bash
#
# What helmly and epistle-panel have to deliver for the archive to admit them,
# run from a release that does not exist yet: a minimal .deb of each, built here,
# signed with a key made here, taken through the roster check, the
# verification that admits a package. The installer and the build of the archive
# are in tests/build/new-product-archive.test.sh. Nothing here reads the real roster, the real release key or a real
# release: the roster is a copy of publish.yml with its own PRODUCTS line, and the
# key exists for this run only.
#
# helmly is built for amd64 and arm64, epistle-panel for `all`, which are the two
# shapes the archive has to serve. The day either one cuts a first release, the
# only edit apt needs is its entry in PRODUCTS, and docs/product-contract.md is the
# list of what the release has to carry for this suite to stay true of it.
#
# Every refusal asserts which refusal fired, and is paired with the acceptance of
# the same release one detail away, so a fixture refused for another reason proves
# nothing.
#
# Requires: bash, python3 with `cryptography`, dpkg-deb, gpg.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
# This run gets a keyring of its own, so the kill below reaches that one and
# not the machine's. Measured 2026-11-27: killing the agent leaves the folder
# of sockets GnuPG made for it under /run, so that folder is removed as well.
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
cleanup() {
	timeout 10 gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	gpgconf --homedir "$GNUPGHOME" --remove-socketdir > /dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT
pass=0; fail=0
VERIFY="$HERE/scripts/verify/verify-debs.sh"
TAG=v1.2.3

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}
said() { grep -qF -- "$1" "$WORK/out" && echo 1 || echo 0; }
verify() { # <dir> <keyfile> <package> <tag> -> exit status, output in $WORK/out
	"$VERIFY" --require-tag "$1" "$2" "$3" "$4" > "$WORK/out" 2>&1
	echo $?
}

# --- the release key of this run, and one that is not it ---------------------
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

work = sys.argv[1]
for name in ("release", "stranger"):
    key = Ed25519PrivateKey.generate()
    open(os.path.join(work, name + ".priv"), "w").write(base64.b64encode(
        key.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())).decode())
    open(os.path.join(work, name + ".pub"), "w").write(base64.b64encode(
        key.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode() + "\n")
PY
sign() { # <deb> <key name>: the detached signature a product's release workflow attaches
	python3 -I - "$WORK/$2.priv" "$1" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(sys.argv[1]).read()))
open(sys.argv[2] + ".sig", "wb").write(key.sign(open(sys.argv[2], "rb").read()))
PY
}

# --- a minimal package of each product ---------------------------------------
build_deb() { # <dir> <file name> <Package> <Version> <Architecture>
	local root="$WORK/root-$RANDOM"
	mkdir -p "$root/DEBIAN" "$1"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture of %s\n' \
		"$3" "$4" "$5" "$3" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$1/$2" > /dev/null 2>&1
}
release() { # <dir> <package> <arch...>: the assets of a release, signed
	local d="$1" p="$2" a; shift 2
	for a in "$@"; do build_deb "$d" "${p}_1.2.3_${a}.deb" "$p" 1.2.3 "$a"; sign "$d/${p}_1.2.3_${a}.deb" release; done
}
release "$WORK/helmly" helmly amd64 arm64
release "$WORK/panel" epistle-panel all

# --- the roster check sees what the publish will ask for ----------------------
mkdir -p "$WORK/bin" "$WORK/repo/.github/workflows" "$WORK/repo/scripts/verify"
cp "$HERE/scripts/verify/roster-has-releases.sh" "$WORK/repo/scripts/verify/"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
# A release is the file names of the folder this run built for it: gh release view --repo <org>/<p>
repo=""; while [ "$#" -gt 0 ]; do [ "$1" = "--repo" ] && repo="$2"; shift; done
dir="$FAKE_RELEASES/${repo#*/}"
[ -d "$dir" ] || { echo "release not found" >&2; exit 1; }
printf 'v1.2.3\n'; ls "$dir" | grep -v '^$'
GH
chmod +x "$WORK/bin/gh"
roster() { # <PRODUCTS value> -> exit status
	printf 'env:\n  ARCHITECTURES: "amd64 arm64"\n  PRODUCTS: "%s"\n' "$1" > "$WORK/repo/.github/workflows/publish.yml"
	PATH="$WORK/bin:$PATH" FAKE_RELEASES="$WORK/releases" "$WORK/repo/scripts/verify/roster-has-releases.sh" > "$WORK/out" 2>&1
	echo $?
}
mkdir -p "$WORK/releases"; ln -s "$WORK/helmly" "$WORK/releases/helmly"; ln -s "$WORK/panel" "$WORK/releases/epistle-panel"
check "helmly for both architectures and epistle-panel for all are usable releases" "0" "$(roster 'helmly epistle-panel:all')"
check "epistle-panel with no architecture declared would be looked for as amd64 and arm64, and is refused" "1" "$(roster 'helmly epistle-panel')"
check "and the refusal names the product and the architecture it lacks" "1" "$(said "epistle-panel's v1.2.3 release carries 0 amd64 .deb")"
rm "$WORK/panel/epistle-panel_1.2.3_all.deb.sig"
check "a release with its .deb and no .sig is refused" "1" "$(roster 'helmly epistle-panel:all')"
sign "$WORK/panel/epistle-panel_1.2.3_all.deb" release
check "and is usable again once the signature is attached" "0" "$(roster 'helmly epistle-panel:all')"

# --- the verification that admits a package ------------------------------------
check "helmly's two packages, signed by the release key and bound to its tag, are admitted" "0" "$(verify "$WORK/helmly" "$WORK/release.pub" helmly "$TAG")"
check "epistle-panel's architecture all package is admitted" "0" "$(verify "$WORK/panel" "$WORK/release.pub" epistle-panel "$TAG")"
check "a tag without the v is the same release" "0" "$(verify "$WORK/panel" "$WORK/release.pub" epistle-panel 1.2.3)"

check "a package from another release is refused" "1" "$(verify "$WORK/panel" "$WORK/release.pub" epistle-panel v1.2.4)"
check "and the refusal says the version does not match the release" "1" "$(said 'version mismatch')"
check "a release that gives no tag is refused when the tag is required" "1" "$(verify "$WORK/panel" "$WORK/release.pub" epistle-panel '')"
check "helmly's package under epistle-panel's name is refused" "1" "$(verify "$WORK/helmly" "$WORK/release.pub" epistle-panel "$TAG")"
check "and the refusal names the package the .deb really is" "1" "$(said 'helmly')"

# A signature made by another key that is valid on its own is no signature of ours.
release "$WORK/stranger" epistle-panel all; sign "$WORK/stranger/epistle-panel_1.2.3_all.deb" stranger
check "a package signed by another valid Ed25519 key is refused" "1" "$(verify "$WORK/stranger" "$WORK/release.pub" epistle-panel "$TAG")"
check "and the refusal is the signature" "1" "$(said 'invalid signature for')"
check "while the same package is admitted by the key that signed it" "0" "$(verify "$WORK/stranger" "$WORK/stranger.pub" epistle-panel "$TAG")"

# The architecture in the file name is not part of what was signed.
mkdir -p "$WORK/renamed"; cp "$WORK/panel/epistle-panel_1.2.3_all.deb" "$WORK/renamed/epistle-panel_1.2.3_amd64.deb"
cp "$WORK/panel/epistle-panel_1.2.3_all.deb.sig" "$WORK/renamed/epistle-panel_1.2.3_amd64.deb.sig"
check "an all package attached under an amd64 name is refused" "1" "$(verify "$WORK/renamed" "$WORK/release.pub" epistle-panel "$TAG")"
check "and the refusal is the architecture" "1" "$(said 'architecture mismatch')"

mkdir -p "$WORK/prefix"; cp "$WORK/panel/epistle-panel_1.2.3_all.deb" "$WORK/prefix/panel_1.2.3_all.deb"
cp "$WORK/panel/epistle-panel_1.2.3_all.deb.sig" "$WORK/prefix/panel_1.2.3_all.deb.sig"
check "a file name that does not start with the product is refused" "1" "$(verify "$WORK/prefix" "$WORK/release.pub" epistle-panel "$TAG")"

mkdir -p "$WORK/bytes"; cp "$WORK/panel/"* "$WORK/bytes/"; printf 'x' >> "$WORK/bytes/epistle-panel_1.2.3_all.deb"
check "a package altered after it was signed is refused" "1" "$(verify "$WORK/bytes" "$WORK/release.pub" epistle-panel "$TAG")"
check "and the refusal is the signature" "1" "$(said 'invalid signature for')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
