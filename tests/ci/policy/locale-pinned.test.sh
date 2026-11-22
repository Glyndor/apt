#!/usr/bin/env bash
#
# `sort` compares under the environment's collation. UTF-8 collations ignore
# punctuation at the primary level, so two strings that differ only there --
# `pod-up` and `podup`, both legal package names -- compare EQUAL and `sort -u`
# drops one. A list that genuinely differs then compares the same.
#
# That is not a hypothetical. It shipped: scripts/build/build-index-page.sh dropped a
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
# tests/build/build-index-page.test.sh, which builds a page under a locale that really
# does collapse two names.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/../../.." || exit 1
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
	while IFS= read -r f; do
		[ -e "$f" ] || continue
		# A file-wide export covers a script. A workflow is not read that way: its
		# steps are separate shells, so an export in one step pins that step only,
		# and a sort has to carry LC_ALL=C on its own line.
		case "$f" in
			*.sh) grep -qE '^[[:space:]]*export[[:space:]]+LC_ALL=C\b' "$f" && continue ;;
		esac
		grep -nE '(^|[|;&(]|\s)sort\b' "$f" 2>/dev/null \
			| grep -v '^[0-9]*:[[:space:]]*#' \
			| grep -v 'LC_ALL=C[[:space:]]*sort' \
			| while IFS= read -r line; do echo "$f:$line"; done
	done < <({
		find scripts -type f -name '*.sh'
		# keyring/upgrade/ runs as root on every client and is held to the same gates
		# as scripts/ (check-test-coverage): its maintainer scripts have no extension,
		# and the units beside them are not shell.
		find keyring/upgrade -type f ! -name '*.service' ! -name '*.timer'
		find .github/workflows -maxdepth 1 -type f -name '*.yml'
	} 2>/dev/null | LC_ALL=C sort)
}

found="$(unpinned || true)"
check "every sort in scripts/, keyring/upgrade/ and the workflows pins its collation" "" "$found"

# The check must be able to see a violation, or it is a grep that always agrees.
# Rather than write to a tracked file, run the same pattern over a fixture.
probe="$(mktemp -d)"
mkdir -p "$probe/scripts"
printf '#!/bin/sh\nprintf "b\\na\\n" | sort -u\n' > "$probe/scripts/bad.sh"
printf '#!/bin/sh\nexport LC_ALL=C\nprintf "b\\na\\n" | sort -u\n' > "$probe/scripts/exported.sh"
printf '#!/bin/sh\nprintf "b\\na\\n" | LC_ALL=C sort -u\n' > "$probe/scripts/inline.sh"
mkdir -p "$probe/scripts/area/sub"
printf '#!/bin/sh\nprintf "b\\na\\n" | sort -u\n' > "$probe/scripts/area/sub/deep.sh"
mkdir -p "$probe/keyring/upgrade"
printf '#!/bin/sh\nprintf "b\\na\\n" | sort -u\n' > "$probe/keyring/upgrade/maintainer-bad"
printf '#!/bin/sh\nprintf "b\\na\\n" | LC_ALL=C sort -u\n' > "$probe/keyring/upgrade/maintainer-pinned"
printf '[Service]\nExecStart=/usr/bin/sort -u\n' > "$probe/keyring/upgrade/unit.service"
# A workflow's run: block sorts too. A file-wide export does not cover it, and a
# comment that names sort -u is not a call.
mkdir -p "$probe/.github/workflows"
printf 'jobs:\n  j:\n    steps:\n      - run: |\n          git ls-files | sort -u\n' > "$probe/.github/workflows/bad.yml"
printf 'jobs:\n  j:\n    steps:\n      - run: |\n          git ls-files | LC_ALL=C sort -u\n          # sort -u is unpinned here, said in prose\n' > "$probe/.github/workflows/good.yml"
printf 'jobs:\n  j:\n    steps:\n      - run: |\n          export LC_ALL=C\n          git ls-files | sort -zu\n' > "$probe/.github/workflows/exported.yml"
seen="$( cd "$probe" || exit 1; unpinned | grep -c . )"
yml_bad="$( cd "$probe" || exit 1; unpinned | grep -c 'workflows/bad.yml' )"
yml_good="$( cd "$probe" || exit 1; unpinned | grep -c 'workflows/good.yml' )"
yml_exported="$( cd "$probe" || exit 1; unpinned | grep -c 'workflows/exported.yml' )"
named="$( cd "$probe" || exit 1; unpinned | grep -c 'bad.sh' )"
deep="$( cd "$probe" || exit 1; unpinned | grep -c 'area/sub/deep.sh' )"
keyring="$( cd "$probe" || exit 1; unpinned | grep -c 'keyring/upgrade/maintainer-bad' )"
others="$( cd "$probe" || exit 1; unpinned | grep -c 'keyring/upgrade/\(maintainer-pinned\|unit.service\)' )"
rm -rf "$probe"
check "and it reports the unpinned sorts at every depth, workflows included" "5" "$seen"
check "and names the file it is in" "1" "$named"
check "and names the one in a nested folder" "1" "$deep"
check "and names the one in keyring/upgrade, which has no extension" "1" "$keyring"
check "and not a pinned one there, nor a unit that names sort" "0" "$others"
check "and names the sort of a workflow's run block" "1" "$yml_bad"
check "and does not name a workflow that pins it on the line, or one that only says sort in a comment" "0" "$yml_good"
check "and does not take an export in one step for a pin on the sort of another line" "1" "$yml_exported"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
