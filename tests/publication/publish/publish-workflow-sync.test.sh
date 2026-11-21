#!/usr/bin/env bash
#
# The sync policy of publish.yml: the five `aws s3 sync` passes, what each of
# them is allowed to write and what each of them is allowed to delete.
#
# Pass 1 uploads pool/ without deleting, pass 2 uploads the by-hash copies of
# the index files, pass 3 publishes the rest of the metadata, pass 4 the signed
# index, and pass 5 removes the pool entries the new metadata stopped
# referencing. The order is the invariant: deleting before the metadata is
# published leaves apt fetching a .deb that is already gone, publishing metadata
# before the packages leaves it referencing files that have not arrived, and an
# InRelease that lands before the copies it declares sends a client that asks
# by hash to a 404. tests/publish/sync-archive.test.sh runs the passes against a
# model of the bucket and checks each point a pass can fail at.
#
# The cases read the commands, never the prose. The comments in this workflow
# discuss `aws s3 sync` by name, and an unanchored grep counts those too -- it
# reported five passes where there are three.
#
# The order of the steps around the sync, and the purge that follows it, are in
# tests/publication/publish/publish-workflow.test.sh.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/../../.." || exit 1
WF=".github/workflows/publish.yml"
# The workflow delegates the passes to this script.
SYNC="scripts/publish/sync-archive.sh"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# --- the five-pass sync -----------------------------------------------------
#
check "the workflow invokes the sync script" "1" \
	"$(grep -c '^          ./scripts/publish/sync-archive.sh$' "$WF")"

# Anchored to the command's own indentation.
mapfile -t starts < <(grep -n '^aws s3 sync' "$SYNC" | cut -d: -f1)
check "the publish step syncs in five passes" "5" "${#starts[@]}"
starts+=("$(($(wc -l < "$SYNC") + 1))")

# Each pass's flags: from its own line up to the next pass, with comment lines
# dropped. A comment says "Deliberately NOT --delete", which is enough to make
# an unfiltered range report that a pass deletes. Every assertion in this file
# reads commands, never prose.
flags_of() { # <pass number, from 1>
	sed -n "${starts[$1 - 1]},$((starts[$1] - 1))p" "$SYNC" | grep -v '^[[:space:]]*#'
}
has() { flags_of "$1" | grep -qF -- "$2" && echo 1 || echo 0; }

check "pass 1 uploads pool/" "1" "$(has 1 '--exclude "*" --include "pool/*"')"
check "and deletes nothing" "0" "$(has 1 '--delete')"
check "pass 2 uploads the by-hash copies, and only them" "1" "$(has 2 '--exclude "*" --include "dists/*/by-hash/*"')"
check "and deletes nothing" "0" "$(has 2 '--delete')"
check "pass 3 publishes the metadata but the pool" "1" "$(has 3 '--exclude "pool/*"')"
check "and but the copies" "1" "$(has 3 '--exclude "dists/*/by-hash/*"')"
check "and but the signed index" "1" \
	"$(has 3 '--exclude "dists/stable/InRelease" --exclude "dists/stable/Release" --exclude "dists/stable/Release.gpg"')"
check "and deletes nothing" "0" "$(has 3 '--delete')"
check "pass 4 publishes the signed index, and only it" "1" \
	"$(has 4 '--exclude "*" --include "dists/stable/InRelease" --include "dists/stable/Release" --include "dists/stable/Release.gpg"')"
check "and deletes nothing" "0" "$(has 4 '--delete')"
check "pass 5 is the one that deletes, and only in pool/" "11" "$(has 5 '--delete')$(has 5 '--exclude "*" --include "pool/*"')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
