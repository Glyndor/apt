#!/usr/bin/env bash
#
# Tests for scripts/verify/roster-has-releases.sh. A fake `gh` answers per repository, so no
# case touches the network. The checks are the ones publish.yml makes before downloading: a
# release, and exactly one `*_<arch>.deb` and one `*_<arch>.deb.sig` for every architecture
# the entry declares. The outcomes stay distinct: 0 every product is usable, 1 a product has
# none or one the publish would refuse, 2 the answer could not be obtained.
#
# Requires: bash.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

mkdir -p "$WORK/bin" "$WORK/repo/.github/workflows" "$WORK/repo/scripts/verify"
cp "$HERE/scripts/verify/roster-has-releases.sh" "$WORK/repo/scripts/verify/"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
sub="$1 $2"; third="${3:-}"; repo=""
while [ "$#" -gt 0 ]; do
	[ "$1" = "--repo" ] && repo="$2"
	shift
done
if [ "$sub" = "repo view" ]; then
	case "$third" in *no-such-repo*) exit 1 ;; esac
	echo ok; exit 0
fi
p="${repo#*/}"
case "$p" in
	good) printf 'v1.0.0\ngood_1.0.0_amd64.deb\ngood_1.0.0_amd64.deb.sig\ngood_1.0.0_arm64.deb\ngood_1.0.0_arm64.deb.sig\n' ;;
	good-all) printf 'v1.0.0\ngood-all_1.0.0_all.deb\ngood-all_1.0.0_all.deb.sig\n' ;;
	tarball-only) printf 'v1.0.0\ntarball-only-1.0.0.tar.gz\n' ;;
	no-sig) printf 'v1.0.0\nno-sig_1.0.0_amd64.deb\nno-sig_1.0.0_arm64.deb\nno-sig_1.0.0_arm64.deb.sig\n' ;;
	two-debs) printf 'v1.0.0\ntwo-debs_1.0.0_amd64.deb\ntwo-debs_1.1.0_amd64.deb\ntwo-debs_1.0.0_amd64.deb.sig\ntwo-debs_1.0.0_arm64.deb\ntwo-debs_1.0.0_arm64.deb.sig\n' ;;
	amd64-only) printf 'v1.0.0\namd64-only_1.0.0_amd64.deb\namd64-only_1.0.0_amd64.deb.sig\n' ;;
	no-release|empty-repo) echo "release not found" >&2; exit 1 ;;
	no-such-repo) echo "release not found" >&2; exit 1 ;;
	api-down) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
	*) echo "HTTP 404: Not Found" >&2; exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"

run() { # $1 = the PRODUCTS value, or - to leave the line out
	if [ "$1" = "-" ]; then
		printf 'env:\n  ARCHITECTURES: "amd64 arm64"\n' > "$WORK/repo/.github/workflows/publish.yml"
	else
		printf 'env:\n  ARCHITECTURES: "amd64 arm64"\n  PRODUCTS: "%s"\n' "$1" > "$WORK/repo/.github/workflows/publish.yml"
	fi
	PATH="$WORK/bin:$PATH" bash "$WORK/repo/scripts/verify/roster-has-releases.sh" >"$WORK/out" 2>"$WORK/err"
	echo $?
}

check "a release with a .deb and a .sig for each architecture passes" "0" "$(run 'good')"
check "an all-architecture entry needs the _all package, not the per-architecture ones" "0" "$(run 'good-all:all')"
check "a release that carries only a tarball is refused" "1" "$(run 'tarball-only')"
check "  and the product is named for each architecture it lacks" "2" "$(grep -c '^NONE  tarball-only' "$WORK/out")"
check "a release without a signature for one architecture is refused" "1" "$(run 'no-sig')"
check "a release with two .deb files for one architecture is refused" "1" "$(run 'two-debs')"
check "a release that lacks an architecture the entry declares is refused" "1" "$(run 'amd64-only')"
check "the same release passes when the entry declares only the architecture it has" "0" "$(run 'amd64-only:amd64')"
check "a bare all-architecture entry for a product that ships _all is refused" "1" "$(run 'good-all')"
check "a repository with no release at all is refused" "1" "$(run 'good no-release')"
check "  and the error says the publish stops without one" "1" "$(grep -c 'the publish stops when it cannot resolve one' "$WORK/err")"
check "a repository that does not exist is not a missing release" "2" "$(run 'no-such-repo')"
check "  and the error says the entry is renamed or misspelt" "1" "$(grep -c 'a renamed or misspelt roster entry' "$WORK/err")"
check "a failing lookup is neither a pass nor a missing release" "2" "$(run 'good api-down')"
check "  and says the answer could not be learned" "1" "$(grep -c 'could not learn whether' "$WORK/err")"
check "a missing release and a failing lookup together report the failure" "2" "$(run 'no-release api-down')"
check "a roster that cannot be read fails with 2" "2" "$(run '-')"
check "a name that is not a plain product name is refused with 2" "2" "$(run 'good;touch-x')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
