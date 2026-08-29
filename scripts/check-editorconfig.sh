#!/usr/bin/env bash
# Check the repository against the rules its own `.editorconfig` declares.
#
# `.editorconfig` is a claim about every tracked file, and nothing read it. That
# made it the one file in the repository whose entire job is to describe the
# repository, and which could be wrong about it indefinitely. It was: five files
# across the three channel repositories had no final newline while `[*]`
# declared `insert_final_newline = true`.
#
# WHAT IS CHECKED, and why these four:
#
#   insert_final_newline      a missing newline is invisible in review and shows
#                             up later as a spurious one-line diff in somebody
#                             else's commit, added by their editor
#   end_of_line = lf          a CRLF file breaks `#!` on the runner and the
#                             error names the interpreter, not the line ending
#   trim_trailing_whitespace  same spurious-diff problem, minus the crash
#   charset = utf-8           a stray byte outside UTF-8 makes grep, sed and awk
#                             behave differently depending on the locale
#
# WHAT IS DELIBERATELY NOT CHECKED, with the number that decided it:
#
#   max_line_length = 120     19 files in apt, 11 in homebrew-tap and 10 in
#                             scoop-bucket exceed it today, nearly all of them
#                             prose comments explaining a decision. Enforcing it
#                             would open with ~40 reds across the three, and a
#                             gate that starts red is one somebody switches off.
#                             It also fights the house style, which prefers a
#                             long sentence to a wrapped one. Left out on
#                             purpose; this comment is the record of that.
#
#   indent_style / indent_size   an indentation checker has to understand
#                             continuation lines, heredocs and embedded
#                             languages to avoid false reds, and a false red on
#                             whitespace is the fastest way to teach people to
#                             ignore a check.
#
# `.md` is exempt from the trailing-whitespace rule because `.editorconfig`
# exempts it: two trailing spaces are a hard line break in Markdown.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail=0
checked=0

report() { # $1=file  $2=rule  $3=message
	echo "::error file=$1::$1 $3 (.editorconfig declares $2)" >&2
	fail=1
}

while IFS= read -r -d '' f; do
	[ -f "$f" ] || continue
	# Binary files have no line endings to speak of and no newline to end on.
	# `grep -I` reports no match for a binary file, which is the cheapest
	# reliable test available in a shell.
	grep -Iq . "$f" 2>/dev/null || continue
	[ -s "$f" ] || continue
	checked=$((checked + 1))

	if [ "$(tail -c1 "$f" | wc -l)" -eq 0 ]; then
		report "$f" "insert_final_newline = true" "does not end with a newline"
	fi

	if grep -qU $'\r$' "$f" 2>/dev/null; then
		report "$f" "end_of_line = lf" "has CRLF line endings"
	fi

	case "$f" in
	*.md) ;; # trim_trailing_whitespace = false for Markdown, by declaration
	*)
		if grep -qE '[[:space:]]+$' "$f" 2>/dev/null; then
			report "$f" "trim_trailing_whitespace = true" "has trailing whitespace"
		fi
		;;
	esac

	if ! iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then
		report "$f" "charset = utf-8" "is not valid UTF-8"
	fi
done < <(git ls-files -z)

# A checker that inspected nothing prints the same success line as one that
# inspected everything, so refuse to be that. This has happened here before:
# line-limit reported every file within the limit on every pull request while
# never opening a workflow, because `yml` was absent from its extension list.
if [ "$checked" -eq 0 ]; then
	echo "::error::no tracked files were checked; the file list is empty or the walk is broken" >&2
	exit 1
fi

if [ "$fail" -ne 0 ]; then
	echo "Some tracked files disagree with .editorconfig." >&2
	exit 1
fi

echo "$checked tracked file(s) agree with .editorconfig on the four rules this checks."
