#!/usr/bin/env bash
# Tests for scripts/check-editorconfig.sh.
#
# Every case plants a file that breaks one declared rule and requires the check
# to report that rule by name. A test that only ran the checker against a clean
# tree and expected exit 0 would pass just as happily against a script that
# returns 0 unconditionally, which is the failure this checker was written to
# close in the first place.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/check-editorconfig.sh"
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

# The checker reads the file list from `git ls-files`, so a fixture has to be a
# git repository with the file committed. An uncommitted file is invisible to
# it, which is itself one of the cases below.
sandbox() { # $1=name -> prints the path
	local dir="$WORK/$1"
	rm -rf "$dir"
	mkdir -p "$dir/scripts"
	git init -q -b main "$dir"
	git -C "$dir" config user.email t@example.invalid
	git -C "$dir" config user.name t
	cp "$SCRIPT" "$dir/scripts/check-editorconfig.sh"
	chmod +x "$dir/scripts/check-editorconfig.sh"
	cp "$HERE/.editorconfig" "$dir/.editorconfig"
	printf '%s' "$dir"
}

commit_all() { git -C "$1" add -A && git -C "$1" commit -qm fixture; }
run() { ( cd "$1" && ./scripts/check-editorconfig.sh 2>&1 ); }

# --- this repository ------------------------------------------------------

out="$("$SCRIPT" 2>&1)"
rc=$?
check "this repository agrees with its own .editorconfig" "0" "$rc"

# A count of zero would satisfy the assertion above while proving nothing.
n="$(printf '%s' "$out" | sed -n 's/^\([0-9]\+\) tracked file.*/\1/p')"
check "and the checker says how many files it read" "1" \
	"$([ -n "$n" ] && echo 1 || echo 0)"
check "and that count is greater than zero" "1" \
	"$([ "${n:-0}" -gt 0 ] && echo 1 || echo 0)"

# --- a missing final newline ---------------------------------------------

d="$(sandbox nl)"
printf 'no newline at the end' > "$d/offender.txt"
commit_all "$d"
out="$(run "$d")"; rc=$?
check "a file with no final newline fails" "1" "$rc"
check "and the error names the file" "1" \
	"$(printf '%s' "$out" | grep -q 'offender.txt' && echo 1 || echo 0)"
check "and names the rule it broke" "1" \
	"$(printf '%s' "$out" | grep -q 'insert_final_newline' && echo 1 || echo 0)"

# --- CRLF line endings ----------------------------------------------------

d="$(sandbox crlf)"
printf 'one\r\ntwo\r\n' > "$d/windows.txt"
commit_all "$d"
out="$(run "$d")"; rc=$?
check "a CRLF file fails" "1" "$rc"
check "and names end_of_line rather than the newline rule" "1" \
	"$(printf '%s' "$out" | grep -q 'end_of_line' && echo 1 || echo 0)"

# --- trailing whitespace --------------------------------------------------

d="$(sandbox ws)"
printf 'trailing spaces here   \nand a clean line\n' > "$d/spaces.txt"
commit_all "$d"
out="$(run "$d")"; rc=$?
check "trailing whitespace fails" "1" "$rc"
check "and names trim_trailing_whitespace" "1" \
	"$(printf '%s' "$out" | grep -q 'trim_trailing_whitespace' && echo 1 || echo 0)"

# --- Markdown is exempt from that one, by declaration ---------------------
#
# `.editorconfig` sets trim_trailing_whitespace = false for `*.md`, because two
# trailing spaces are a hard line break in Markdown. A checker that ignored the
# exemption would be wrong in the direction that trains people to ignore it.

d="$(sandbox md)"
printf 'a line ending in a hard break  \nnext line\n' > "$d/notes.md"
commit_all "$d"
out="$(run "$d")"; rc=$?
check "trailing whitespace in Markdown is allowed" "0" "$rc"

# --- invalid UTF-8 --------------------------------------------------------

d="$(sandbox utf)"
printf 'valid then \xff\xfe invalid\n' > "$d/bytes.txt"
commit_all "$d"
out="$(run "$d")"; rc=$?
check "a file that is not valid UTF-8 fails" "1" "$rc"
check "and names charset" "1" \
	"$(printf '%s' "$out" | grep -q 'charset' && echo 1 || echo 0)"

# --- an untracked file is invisible ---------------------------------------
#
# Not a gap: the checker deliberately follows `git ls-files`, so it describes
# what the repository contains rather than what the working tree happens to.

d="$(sandbox untracked)"
printf 'clean\n' > "$d/tracked.txt"
commit_all "$d"
printf 'no newline' > "$d/loose.txt"
out="$(run "$d")"; rc=$?
check "an untracked offender is not reported" "0" "$rc"

# --- a tree with nothing to check must fail, not pass ---------------------

d="$(sandbox empty)"
rm -f "$d/.editorconfig"
git -C "$d" rm -q --cached scripts/check-editorconfig.sh 2>/dev/null || true
rm -rf "$d/scripts" "$d/.editorconfig"
mkdir -p "$d/scripts"
cp "$SCRIPT" "$d/scripts/check-editorconfig.sh"
chmod +x "$d/scripts/check-editorconfig.sh"
git -C "$d" commit -q --allow-empty -m empty >/dev/null 2>&1
out="$(run "$d")"; rc=$?
check "a tree with no tracked files fails rather than reporting success" "1" "$rc"
check "and says the walk found nothing" "1" \
	"$(printf '%s' "$out" | grep -q 'no tracked files' && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
