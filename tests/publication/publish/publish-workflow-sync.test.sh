#!/usr/bin/env bash
#
# The sync policy of publish.yml: the three `aws s3 sync` passes, what each of
# them is allowed to write and what each of them is allowed to delete.
#
# Pass 1 uploads pool/ without deleting, pass 2 publishes the metadata, pass 3
# removes the pool entries the new metadata stopped referencing. The order is
# the invariant: deleting before the metadata is published leaves apt fetching
# a .deb that is already gone, and publishing metadata before the packages
# leaves it referencing files that have not arrived.
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
# The workflow delegates the unchanged three passes to this script.
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

# --- the three-pass sync ----------------------------------------------------
#
check "the workflow invokes the sync script" "1" \
	"$(grep -c '^          ./scripts/publish/sync-archive.sh$' "$WF")"
# Anchored to the command's own indentation.
sync_lines="$(grep -n '^aws s3 sync' "$SYNC" | cut -d: -f1)"
check "the publish step syncs in three passes" "3" \
	"$(printf '%s\n' "$sync_lines" | grep -c .)"

p1="$(printf '%s\n' "$sync_lines" | sed -n 1p)"
p2="$(printf '%s\n' "$sync_lines" | sed -n 2p)"
p3="$(printf '%s\n' "$sync_lines" | sed -n 3p)"

# Read each pass's flags: from its own line up to the next pass (or the end of
# the step), so a flag cannot be attributed to the wrong invocation -- and with
# comment lines dropped. The comment introducing pass 2 says "Deliberately NOT
# --delete", which is enough to make an unfiltered range report that pass 1
# deletes. Every assertion in this file reads commands, never prose.
flags_of() { sed -n "${1},${2}p" "$SYNC" | grep -v '^[[:space:]]*#'; }

check "pass 1 uploads pool/ and deletes nothing" "1" \
	"$(flags_of "$p1" "$((p2 - 1))" | grep -q -- '--include "pool/\*"' && \
	   ! flags_of "$p1" "$((p2 - 1))" | grep -q -- '--delete' && echo 1 || echo 0)"

check "pass 2 publishes the metadata without --delete" "1" \
	"$(flags_of "$p2" "$((p3 - 1))" | grep -q -- '--exclude "pool/\*"' && \
	   ! flags_of "$p2" "$((p3 - 1))" | grep -q -- '--delete' && echo 1 || echo 0)"

check "pass 3 is the one that deletes, and only in pool/" "1" \
	"$(flags_of "$p3" "$((p3 + 6))" | grep -q -- '--delete' && \
	   flags_of "$p3" "$((p3 + 6))" | grep -q -- '--include "pool/\*"' && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
