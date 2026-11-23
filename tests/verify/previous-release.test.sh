#!/usr/bin/env bash
#
# scripts/verify/previous-release.sh fetches the .deb a product shipped before the one the archive
# serves, so that an upgrade to the served one can be tried. The upgrade is only worth what its
# starting point is worth, so each way the script could hand over the wrong package, or one it did
# not check, has to be shown here to be refused: a release above the served version, a draft or a
# pre-release, a download that is not the bytes GitHub reports, a file that declares another
# package or version than its name, and a product with nothing below the served version, which is
# a different exit from a failure.
#
# The script is run as it ships, with gh and curl replaced by stubs on PATH and real .deb files
# built on the spot. No network.
#
# Requires: bash, jq, dpkg-deb.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/previous-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

for tool in jq dpkg-deb sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || { echo "NOTE  $tool is missing, so nothing below could run. Not a pass."; exit 1; }
done

PRODUCT=prev-probe
FIX="$WORK/fix"; mkdir -p "$FIX" "$WORK/bin"

deb() { # <file name> <package> <version>
	local d="$WORK/build.$$"
	rm -rf "$d"; mkdir -p "$d/DEBIAN"
	printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@example.invalid>\nDescription: probe\n' "$2" "$3" > "$d/DEBIAN/control"
	dpkg-deb -b "$d" "$FIX/$1" >/dev/null 2>&1
}
digest() { printf 'sha256:%s' "$(sha256sum "$FIX/$1" | cut -d' ' -f1)"; }

deb "${PRODUCT}_1.0.0_amd64.deb" "$PRODUCT" 1.0.0
deb "${PRODUCT}_1.5.0_amd64.deb" "$PRODUCT" 1.5.0
deb "${PRODUCT}_1.9.0_amd64.deb" "$PRODUCT" 1.9.0
deb "${PRODUCT}_2.0.0_amd64.deb" "$PRODUCT" 2.0.0
deb "${PRODUCT}_2.1.0_amd64.deb" "$PRODUCT" 2.1.0
# A file whose name says 1.2.0 and whose control says something else.
deb "${PRODUCT}_1.2.0_amd64.deb" "$PRODUCT" 1.3.0
deb "${PRODUCT}_1.4.0_amd64.deb" "another-package" 1.4.0

release() { # <tag> <draft> <prerelease> <asset file or ->  [digest override]
	local tag="$1" draft="$2" pre="$3" asset="$4" dig="${5-}"
	[ -z "$dig" ] && [ "$asset" != - ] && dig="$(digest "$asset")"
	jq -n --arg tag "$tag" --argjson draft "$draft" --argjson pre "$pre" --arg name "$asset" --arg dig "$dig" '
		{tag_name: $tag, draft: $draft, prerelease: $pre,
		 assets: (if $name == "-" then [] else [{name: $name, digest: (if $dig == "" then null else $dig end)}, {name: ($name + ".sig"), digest: "sha256:00"}] end)}'
}

cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
	api)
		[ -n "${STUB_GH_API_FAIL:-}" ] && exit 1
		cat "$STUB_RELEASES" ;;
	release)
		[ -n "${STUB_DOWNLOAD_FAIL:-}" ] && exit 1
		dir=""; pattern=""
		while [ $# -gt 0 ]; do
			case "$1" in --dir) dir="$2"; shift ;; --pattern) pattern="$2"; shift ;; esac
			shift
		done
		[ -n "${STUB_DOWNLOAD_EMPTY:-}" ] && exit 0
		if [ -n "${STUB_DOWNLOAD_AS:-}" ]; then cp "$FIX/$STUB_DOWNLOAD_AS" "$dir/$pattern"; else cp "$FIX/$pattern" "$dir/$pattern"; fi ;;
esac
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CURL_FAIL:-}" ] && exit 22
printf '%s' "$STUB_INDEX"
STUB
chmod +x "$WORK/bin"/*

index() { printf 'Package: other\nVersion: 9.9.9\nArchitecture: amd64\n\nPackage: %s\nVersion: %s\nArchitecture: amd64\n' "$PRODUCT" "$1"; }

# run_prev <served or empty> <releases json array> -> output on $WORK/out, status in $rc
run_prev() {
	local served="$1" releases="$2"
	printf '[%s]\n' "$releases" > "$WORK/releases.json"
	rm -rf "$WORK/dest"
	STUB_RELEASES="$WORK/releases.json" STUB_INDEX="$(index 2.0.0)" FIX="$FIX" PATH="$WORK/bin:$PATH" \
		bash "$SCRIPT" "${PRODUCT_ARG:-$PRODUCT}" "$WORK/dest" ${served:+"$served"} > "$WORK/stdout" 2> "$WORK/stderr"
	rc=$?
}
said() { grep -c -- "$1" "$WORK/stderr"; }

R1="$(release v1.0.0 false false "${PRODUCT}_1.0.0_amd64.deb")"
R15="$(release v1.5.0 false false "${PRODUCT}_1.5.0_amd64.deb")"
R19="$(release v1.9.0 false true "${PRODUCT}_1.9.0_amd64.deb")"
R2="$(release v2.0.0 false false "${PRODUCT}_2.0.0_amd64.deb")"
R21="$(release v2.1.0 false false "${PRODUCT}_2.1.0_amd64.deb")"
RD="$(release v1.8.0 true false "${PRODUCT}_1.5.0_amd64.deb")"

# --- the release below the served one ------------------------------------------------------------------

run_prev "" "$R21,$R2,$R15,$R1"
check "the newest release below the served version, read from the index, is the one fetched" "0" "$rc"
check "and its path is on stdout" "$WORK/dest/${PRODUCT}_1.5.0_amd64.deb" "$(cat "$WORK/stdout")"
check "and the file is there" "1" "$([ -f "$WORK/dest/${PRODUCT}_1.5.0_amd64.deb" ] && echo 1 || echo 0)"
check "and the log says which release it is and what it is below" "1" "$(said 'prev-probe 1.5.0 from Glyndor/prev-probe v1.5.0, below the served 2.0.0')"

run_prev 2.1.0 "$R21,$R2,$R15,$R1"
check "a served version given on the command line is the one it goes below" "$WORK/dest/${PRODUCT}_2.0.0_amd64.deb" "$(cat "$WORK/stdout")"

run_prev 2.0.0 "$R19,$R15"
check "a pre-release below the served version is not a release to start from" "$WORK/dest/${PRODUCT}_1.5.0_amd64.deb" "$(cat "$WORK/stdout")"
run_prev 2.0.0 "$RD,$R1"
check "a draft is not either" "$WORK/dest/${PRODUCT}_1.0.0_amd64.deb" "$(cat "$WORK/stdout")"

# --- nothing below the served version ----------------------------------------------------------------------

run_prev 1.0.0 "$R1,$R15,$R2"
check "no release below the served version is exit 3" "3" "$rc"
check "and says an upgrade cannot be tried" "1" "$(said 'cannot be tried')"
check "and prints no path" "" "$(cat "$WORK/stdout")"
run_prev 2.0.0 "$(release v1.0.0 false false -)"
check "a release with no package for the architecture is not a candidate" "3" "$rc"

# --- what is downloaded is held to what GitHub reports and to what the file says ---------------------------

run_prev 2.0.0 "$(release v1.0.0 false false "${PRODUCT}_1.0.0_amd64.deb" "sha256:$(printf '%064d' 0)")"
check "bytes that are not the digest GitHub reports fail" "1" "$rc"
check "and say which digest it is" "1" "$(said 'is sha256:')"
# release() fills an empty digest with the real one, so the missing one is planted by hand.
run_prev 2.0.0 "$R1"
printf '[%s]\n' "$(jq -c '.assets[0].digest = null' <<<"$R1")" > "$WORK/releases.json"
STUB_RELEASES="$WORK/releases.json" STUB_INDEX="$(index 2.0.0)" FIX="$FIX" PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$PRODUCT" "$WORK/dest" > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
check "a release that reports no digest fails, since the download cannot be checked" "1" "$rc"
check "and says so" "1" "$(said 'reports no sha256 digest')"
run_prev 2.0.0 "$(release v1.2.0 false false "${PRODUCT}_1.2.0_amd64.deb")"
check "a file whose control says another version than its name fails" "1" "$rc"
check "and says which version it declares" "1" "$(said 'declares version 1.3.0, not 1.2.0')"
run_prev 2.0.0 "$(release v1.4.0 false false "${PRODUCT}_1.4.0_amd64.deb")"
check "a file that declares another package fails" "1" "$rc"
check "and says so" "1" "$(said 'does not declare the package prev-probe')"

# --- failures of what it reads ------------------------------------------------------------------------------

ORG='a b' run_prev 2.0.0 "$R1"
check "an organisation name with a space is refused" "1" "$rc"
check "and says it is not a plain name" "1" "$(said 'not a plain organisation name')"
ARCH='a/b' run_prev 2.0.0 "$R1"
check "an architecture with a slash is refused" "1" "$rc"
check "and says it is not an architecture" "1" "$(said 'is not an architecture')"
: > "$WORK/afile"
rm -rf "$WORK/dest"
STUB_RELEASES="$WORK/releases.json" STUB_INDEX="$(index 2.0.0)" FIX="$FIX" PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$PRODUCT" "$WORK/afile/sub" 2.0.0 > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
check "a directory that cannot be created is refused" "1" "$rc"
check "and says so" "1" "$(said 'cannot create')"
printf '[%s]\n' "$(jq -c '.assets[0].digest = "md5:abc"' <<<"$R1")" > "$WORK/releases.json"
STUB_RELEASES="$WORK/releases.json" STUB_INDEX="$(index 2.0.0)" FIX="$FIX" PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$PRODUCT" "$WORK/dest" 2.0.0 > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
check "a digest that is not a sha256 is refused as one that is missing" "1" "$(said 'reports no sha256 digest')"

PRODUCT_ARG='../x' run_prev 2.0.0 "$R1"
check "a product name with a path in it is refused" "1" "$rc"
check "and says it is not a plain name" "1" "$(said 'not a plain product name')"
STUB_GH_API_FAIL=1 run_prev 2.0.0 "$R1"
check "a listing of the releases that fails stops it" "1" "$rc"
check "and says which repository" "1" "$(said 'could not list the releases of Glyndor/prev-probe')"
printf '{"message":"Not Found"}\n' > "$WORK/notalist.json"
STUB_RELEASES="$WORK/notalist.json" STUB_INDEX="$(index 2.0.0)" FIX="$FIX" PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$PRODUCT" "$WORK/dest" 2.0.0 > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
check "an answer that is not a list of releases stops it" "1" "$rc"
STUB_DOWNLOAD_FAIL=1 run_prev 2.0.0 "$R1"
check "a download that fails stops it" "1" "$rc"
check "and says which asset" "1" "$(said "could not download ${PRODUCT}_1.0.0_amd64.deb")"
STUB_DOWNLOAD_EMPTY=1 run_prev 2.0.0 "$R1"
check "a download that leaves no file stops it" "1" "$rc"
check "and says that it left none" "1" "$(said 'left no file')"
STUB_CURL_FAIL=1 run_prev "" "$R1"
check "an index that cannot be read stops it when the served version is not given" "1" "$rc"
check "and says the served version is not known" "1" "$(said 'served version is not known')"
printf '[%s]\n' "$R1" > "$WORK/releases.json"
STUB_RELEASES="$WORK/releases.json" STUB_INDEX="$(printf 'Package: other\nVersion: 1\n')" FIX="$FIX" PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$PRODUCT" "$WORK/dest" > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
check "a product that is not in the index has no served version to go back from" "1" "$rc"
check "and says so" "1" "$(said 'not in the index')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
