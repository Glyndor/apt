#!/usr/bin/env bash
#
# `sort` compares under the environment's collation. UTF-8 collations ignore
# punctuation at the primary level, so two strings that differ only there --
# `pod-up` and `podup`, both legal package names -- compare EQUAL and `sort -u`
# drops one. A list that genuinely differs then compares the same.
#
# That is not a hypothetical. It shipped: scripts/build-index-page.sh dropped a
# package from the published page, and the test that caught it had been red on a
# developer machine and green in CI for as long as it existed, because the
# runner's collation happens not to collapse those two.
#
# It then turned out to be in eight places across three repositories, and five
# of them survived the first pass at fixing it. A grep is cheaper than a sixth
# pass, so this is the grep.
#
# It checks the shape, not the behaviour: `LC_ALL=C` appearing on the line is
# not proof the sort is correct. The behavioural half lives in
# tests/build-index-page.test.sh, which builds a page under a locale that really
# does collapse two names.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Command lines only. The comments in these scripts discuss `sort -u` by name at
# length, and an unanchored grep counts those too -- the same mistake that
# reported five `aws s3 sync` passes where there are three.
# Two idioms count as pinned: `LC_ALL=C sort` on the line, and a bare
# `export LC_ALL=C` at the top of the file, which covers every sort in it. The
# first version of this check filtered LINES containing "export LC_ALL=C" and so
# reported three false positives in a script that used the second idiom -- it
# has to be file-aware, and running it in a repository that uses the other form
# is what showed that.
unpinned() {
	local f line
	for f in scripts/*.sh; do
		[ -e "$f" ] || continue
		grep -qE '^[[:space:]]*export[[:space:]]+LC_ALL=C\b' "$f" && continue
		grep -nE '(^|[|;&(]|\s)sort\b' "$f" 2>/dev/null \
			| grep -v '^[0-9]*:[[:space:]]*#' \
			| grep -v 'LC_ALL=C[[:space:]]*sort' \
			| while IFS= read -r line; do echo "$f:$line"; done
	done
}

found="$(unpinned || true)"
check "every sort in scripts/ pins its collation" "" "$found"

# The check must be able to see a violation, or it is a grep that always agrees.
# Rather than write to a tracked file, run the same pattern over a fixture.
probe="$(mktemp -d)"
mkdir -p "$probe/scripts"
printf '#!/bin/sh\nprintf "b\\na\\n" | sort -u\n' > "$probe/scripts/bad.sh"
printf '#!/bin/sh\nexport LC_ALL=C\nprintf "b\\na\\n" | sort -u\n' > "$probe/scripts/exported.sh"
printf '#!/bin/sh\nprintf "b\\na\\n" | LC_ALL=C sort -u\n' > "$probe/scripts/inline.sh"
seen="$( cd "$probe" || exit 1; unpinned | grep -c . )"
named="$( cd "$probe" || exit 1; unpinned | grep -c 'bad.sh' )"
rm -rf "$probe"
check "and it reports exactly the one unpinned sort" "1" "$seen"
check "and names the file it is in" "1" "$named"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
