#!/usr/bin/env bash
#
# check-index-baseline.sh: which served index may be taken as the current one. The caller has verified the signature, so
# the cases hand it a body and a file of their own; the Date of "now" is fixed with INDEX_NOW.
#
# Requires: python3.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/check-index-baseline.sh"
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
NOW="$(date -u -d 2026-11-26T18:00:00Z +%s)"
# index <Date> <Valid-Until> [text]: the verified body in $WORK/body and the served file in $WORK/InRelease
index() {
	printf 'Origin: Glyndor\nDate: %s\nValid-Until: %s\nSHA256:\n' "$(date -u -d "$1" '+%a, %d %b %Y %H:%M:%S UTC')" \
		"$(date -u -d "$2" '+%a, %d %b %Y %H:%M:%S UTC')" > "$WORK/body"
	{ echo '-----BEGIN PGP SIGNED MESSAGE-----'; cat "$WORK/body"; echo "${3:-signature}"; } > "$WORK/InRelease"
}
sha() { sha256sum "$WORK/InRelease" | cut -d' ' -f1; }
floor() { printf '# the repository record\n%s\n' "$1" > "$WORK/floor"; }
record() { printf '%s\n' "$1" > "$WORK/record"; }
# judge [accept]: the exit status; the output is in $WORK/out
judge() {
	local rc=0
	: > "$WORK/summary"
	INDEX_NOW="$NOW" INDEX_FLOOR="$WORK/floor" INDEX_RECORD="$WORK/record" ACCEPT_OLD_INDEX="${1:-}" \
		GITHUB_STEP_SUMMARY="$WORK/summary" bash "$SCRIPT" "$WORK/body" "$WORK/InRelease" > "$WORK/out" 2>&1 || rc=$?
	echo "$rc"
}
says() { grep -c -F -- "$1" "$WORK/out" || true; }

floor 2026-11-20T00:00:00Z
index 2026-11-26T16:00:00Z 2026-12-10T16:00:00Z
A_SHA="$(sha)"
record "2026-11-26T16:00:00Z $A_SHA"
check "the index the last publication recorded passes" "0" "$(judge)"
index 2026-11-26T17:00:00Z 2026-12-10T17:00:00Z
check "a newer one passes: a publication that recorded nothing is not a rollback" "0" "$(judge)"
record "2026-11-26T17:30:00Z $(printf '%064d' 1)"
check "an index older than the recorded one, signed and not expired, is refused" "1 1" "$(judge) $(says 'older than the one the last publication recorded')"
check "and it names the bucket going back to an earlier index" "1" "$(says 'the bucket was put back to an earlier signed index')"
check "and the edge still serving the copy of before that publication" "1" "$(says 'the edge still serves the copy of before that publication')"
check "and that purging the cache and trying again may settle it" "1" "$(says 'purge the cache and try again')"
check "and says how to accept it" "1" "$(says 'accept_old_index set to its SHA256')"
record "2026-11-26T17:00:00Z $(printf '%064d' 1)"
check "the recorded Date with other bytes is refused" "1 1" "$(judge) $(says 'has the Date the last publication recorded and other bytes')"
record none
check "with nothing recorded, a recent index passes" "0" "$(judge)"
index 2026-11-23T18:00:00Z 2026-12-07T18:00:00Z
check "three days old to the second still passes" "0" "$(judge)"
index 2026-11-23T17:59:59Z 2026-12-07T17:59:59Z
check "older than three days with nothing recorded is refused" "1 1" "$(judge) $(says 'more than 3 days old')"
record "2026-11-23T17:59:59Z $(sha)"
check "and passes once a publication has recorded it, however old" "0" "$(judge)"
index 2026-11-26T16:00:00Z 2026-11-26T18:00:00Z
record "2026-11-26T16:00:00Z $(sha)"
check "an index that expires now is refused" "1 1" "$(judge) $(says 'it expired at 2026-11-26T18:00:00Z')"
index 2026-11-26T18:10:00Z 2026-12-10T18:10:00Z; record none
check "ten minutes ahead of the clock is tolerated" "0" "$(judge)"
index 2026-11-26T18:10:01Z 2026-12-10T18:10:01Z
check "a Date further ahead is refused" "1 1" "$(judge) $(says 'is dated in the future')"
index 2026-11-19T23:59:59Z 2026-12-10T00:00:00Z
record "2026-11-19T23:59:59Z $(sha)"
check "an index older than the record of the repository is refused, whatever the publication recorded" "1 1" \
	"$(judge) $(says 'the oldest')"
index 2026-11-20T00:00:00Z 2026-12-10T00:00:00Z; record "2026-11-20T00:00:00Z $(sha)"
check "the Date of the repository record itself passes" "0" "$(judge)"
floor none
index 2026-11-19T23:59:59Z 2026-12-10T00:00:00Z; record "2026-11-19T23:59:59Z $(sha)"
check "a repository record of none bounds nothing" "0" "$(judge)"

echo "-- accepting one index by hand"
floor 2026-11-01T00:00:00Z
index 2026-11-05T00:00:00Z 2026-11-19T00:00:00Z
OLD_SHA="$(sha)"
record "2026-11-25T00:00:00Z $(printf '%064d' 1)"
check "an expired, older index is refused" "1" "$(judge)"
check "and passes for a run that names its SHA256" "0" "$(judge "$OLD_SHA")"
check "which leaves a warning with the Date and the SHA256 accepted" "1" \
	"$(grep -c -F -- "::warning::accept_old_index: accepted the served index (Date 2026-11-05T00:00:00Z, SHA256 $OLD_SHA); it expired" "$WORK/out" || true)"
check "and the same in the summary of the run" "1" "$(grep -c -F -- "SHA256 $OLD_SHA" "$WORK/summary" || true)"
index 2026-11-06T00:00:00Z 2026-11-20T00:00:00Z
check "another signed index served in its place is refused, though it is newer" "1 1" "$(judge "$OLD_SHA") $(says 'is another one')"
record none; index 2026-11-26T16:00:00Z 2026-12-10T16:00:00Z
check "naming an index that needed no exception passes and still says so" "0 1" "$(judge "$(sha)") $(says 'it needed no exception')"
check "naming another than the one served is refused even then" "1" "$(judge "$OLD_SHA")"
index 2026-10-31T23:59:59Z 2026-12-10T00:00:00Z
check "naming it does not take it below the record of the repository" "1 1" "$(judge "$(sha)") $(says 'the oldest')"
index 2026-11-27T00:00:00Z 2026-12-10T00:00:00Z
check "nor into the future" "1 1" "$(judge "$(sha)") $(says 'is dated in the future')"
index 2026-11-05T00:00:00Z 2026-11-19T00:00:00Z
for bad in true yes "${OLD_SHA:1}" "${OLD_SHA^^}" "$OLD_SHA x"; do
	check "accept_old_index as '${bad:0:12}' is refused" "1 1" "$(judge "$bad") $(says 'takes the SHA256 of the InRelease')"
done

echo "-- a file larger than the limit is refused, not read in part"
floor none; record none
index 2026-11-26T16:00:00Z 2026-12-10T16:00:00Z
head -c $(( (1 << 22) + 1 )) /dev/zero > "$WORK/big"
rc=0; INDEX_NOW="$NOW" INDEX_FLOOR="$WORK/floor" INDEX_RECORD="$WORK/record" \
	bash "$SCRIPT" "$WORK/body" "$WORK/big" > "$WORK/out" 2>&1 || rc=$?
check "an index larger than the limit is refused" "1 1" "$rc $(says 'is larger than')"
head -c $(( (1 << 22) + 1 )) /dev/zero > "$WORK/big-body"
rc=0; INDEX_NOW="$NOW" INDEX_FLOOR="$WORK/floor" INDEX_RECORD="$WORK/record" \
	bash "$SCRIPT" "$WORK/big-body" "$WORK/InRelease" > "$WORK/out" 2>&1 || rc=$?
check "a body larger than the limit is refused" "1 1" "$rc $(says 'is larger than')"
head -c $(( 1 << 22 )) /dev/zero > "$WORK/exact"
rc=0; INDEX_NOW="$NOW" INDEX_FLOOR="$WORK/floor" INDEX_RECORD="$WORK/record" \
	bash "$SCRIPT" "$WORK/body" "$WORK/exact" > "$WORK/out" 2>&1 || rc=$?
check "an index of exactly the limit is read" "0" "$rc"

echo "-- what cannot be read is a refusal"
floor none; record none
index 2026-11-26T16:00:00Z 2026-12-10T16:00:00Z
cp "$WORK/body" "$WORK/body-good"
for name in Date Valid-Until; do
	grep -v "^$name:" "$WORK/body-good" > "$WORK/body"
	check "an index with no $name" "1 1" "$(judge) $(says "does not declare $name exactly once")"
	{ cat "$WORK/body-good"; grep "^$name:" "$WORK/body-good"; } > "$WORK/body"
	check "an index with $name twice" "1 1" "$(judge) $(says "does not declare $name exactly once")"
	sed "s/^$name: .*/$name: yesterday/" "$WORK/body-good" > "$WORK/body"
	check "a $name that is no time" "1 1" "$(judge) $(says 'is not a time in UTC')"
	sed "s/^\($name: .*\) UTC/\1 +0100/" "$WORK/body-good" > "$WORK/body"
	check "a $name outside UTC" "1 1" "$(judge) $(says 'is not a time in UTC')"
done
cp "$WORK/body-good" "$WORK/body"
for bad in "" "2026-11-20" "yesterday" "$(printf 'none\nnone')"; do
	floor "$bad"
	check "a repository record of '${bad:0:12}'" "1" "$(judge)"
done
rm "$WORK/floor"
check "no repository record" "1 1" "$(judge) $(says 'cannot read')"
floor none
for bad in "" "2026-11-20T00:00:00Z" "2026-11-20T00:00:00Z abc" "$(printf 'none\nnone')" "never $(printf '%064d' 1)"; do
	record "$bad"
	check "a publication record of '${bad:0:24}'" "1" "$(judge)"
done
rm "$WORK/record"
check "no publication record" "1 1" "$(judge) $(says 'cannot read')"
record none
rc=0; INDEX_RECORD="" bash "$SCRIPT" "$WORK/body" "$WORK/InRelease" > "$WORK/out" 2>&1 || rc=$?
check "INDEX_RECORD unset" "1 1" "$rc $(says 'INDEX_RECORD is not set')"
rc=0; INDEX_RECORD="$WORK/record" INDEX_NOW=soon bash "$SCRIPT" "$WORK/body" "$WORK/InRelease" > "$WORK/out" 2>&1 || rc=$?
check "INDEX_NOW that is no epoch" "1 1" "$rc $(says 'INDEX_NOW is not an epoch')"
rc=0; bash "$SCRIPT" "$WORK/body" > "$WORK/out" 2>&1 || rc=$?
check "one argument" "2" "$rc"

echo "-- the record the repository ships"
shipped="$(grep -vE '^[[:space:]]*(#|$)' "$HERE/scripts/verify/index-floor.txt")"
check "it is none or one time" "1" "$(grep -cE '^(none|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$' <<< "$shipped")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
