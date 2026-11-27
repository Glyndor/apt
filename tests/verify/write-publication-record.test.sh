#!/usr/bin/env bash
#
# write-publication-record.sh: the record a publication leaves of the index it published is its Date and the SHA256 of
# the file, in the form read-publication-record.sh accepts and check-index-baseline.sh judges by.
#
# Requires: python3.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/write-publication-record.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fail=$((fail + 1))
		sed 's/^/        | /' "$WORK/out" 2> /dev/null
	fi
}
write() { local rc=0; rm -rf "$WORK/kept"; bash "$SCRIPT" "$@" > "$WORK/out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/out" || true; }
printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nDate: Thu, 26 Nov 2026 16:36:00 UTC\nValid-Until: Thu, 10 Dec 2026 16:36:00 UTC\n' > "$WORK/InRelease"
line="2026-11-26T16:36:00Z $(sha256sum "$WORK/InRelease" | cut -d' ' -f1)"

check "the record is written" "0 $line" "$(write "$WORK/InRelease" "$WORK/kept") $(cat "$WORK/kept/published-index")"
check "and printed in the log, where an operator takes it from" "1" "$(says "published index recorded (Date and SHA256 of InRelease): $line")"
echo "$line" > "$WORK/record"; echo none > "$WORK/floor"
sed -n '4,$p' "$WORK/InRelease" > "$WORK/body"
rc=0; INDEX_RECORD="$WORK/record" INDEX_FLOOR="$WORK/floor" INDEX_NOW="$(date -u -d 2026-11-27T00:00:00Z +%s)" \
	bash "$HERE/scripts/verify/check-index-baseline.sh" "$WORK/body" "$WORK/InRelease" > "$WORK/out" 2>&1 || rc=$?
check "the next publication accepts the index it records" "0" "$rc"
check "an index that is not there" "1 1" "$(write "$WORK/nowhere" "$WORK/kept") $(says 'cannot be recorded')"
check "and it says that the index could not be read" "1 1" "$(write "$WORK/nowhere" "$WORK/kept") $(says 'cannot read')"
check "an index that is a folder" "1 1" "$(write "$WORK" "$WORK/kept") $(says 'cannot read')"
check "and nothing is recorded" "no" "$([ -e "$WORK/kept/published-index" ] && echo yes || echo no)"
for edit in '/^Date:/d' 's/^Date: .*/&\n&/' 's/^Date: .*/Date: soon/' 's/ UTC$/ +0200/'; do
	sed "$edit" "$WORK/InRelease" > "$WORK/bad"
	check "an index edited with $edit is not recorded" "1 no" \
		"$(write "$WORK/bad" "$WORK/kept") $([ -e "$WORK/kept/published-index" ] && echo yes || echo no)"
done
check "one argument" "2" "$(write "$WORK/InRelease")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
