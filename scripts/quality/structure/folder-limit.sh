#!/usr/bin/env bash
# Fail when a folder holds more than twenty tracked files directly.
#
# The structure standard caps a folder at twenty files, so a folder that grows past
# it is split by concern instead of collecting siblings. The count is of tracked
# files directly inside each folder, dotfiles and tests included; `.github/workflows`
# is flat because GitHub registers workflows only there, and a `testdata` folder
# holds fixtures that are data and not files somebody wrote.
#
# A folder over the limit is listed in .github/folder-limit-exceptions.txt as
# path<TAB>ceiling<TAB>reason; blank lines and # comments are allowed, and `.` is the
# root. The ceiling must exceed twenty and can only go down: an entry whose folder is
# back at twenty or fewer fails as a dead exception, so an exception does not outlive
# its cause.
#
# BASE names the commit the change merges into. With it, a ceiling that is higher
# than the one the base holds fails, and so does a folder with more files than the
# base's list allows: a change is judged by its own list and by the base's, and has to
# pass both. The workflow that runs this script also takes the
# script from that commit, so a pull request cannot weaken its own gate.
#
# Usage: folder-limit.sh      (from anywhere inside the repository)
set -euo pipefail
export LC_ALL=C

cd "$(git rev-parse --show-toplevel)"
exceptions=.github/folder-limit-exceptions.txt
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
declare -A counts=() ceilings=() parsed=()

ignored() {
	# GitHub registers a workflow only when it sits directly in this folder.
	# Keep fixtures and fuzz corpora under any testdata/ component out of the gate.
	case "/$1/" in
	/.github/workflows/ | */testdata/*) return 0 ;;
	esac
	return 1
}

load_exceptions() {
	local file="$1" line dir rest cap reason number=0
	parsed=()
	while IFS= read -r line || [ -n "$line" ]; do
		number=$((number + 1))
		case "$line" in '' | \#*) continue ;; esac
		if [[ "$line" != *$'\t'* ]]; then
			printf 'folder-limit: %s:%d: expected path<TAB>ceiling<TAB>reason\n' "$file" "$number" >&2
			return 1
		fi
		dir="${line%%$'\t'*}"
		rest="${line#*$'\t'}"
		cap="${rest%%$'\t'*}"
		reason="${rest#*$'\t'}"
		if [[ "$rest" != *$'\t'* || "$reason" == *$'\t'* || ! "$reason" =~ [^[:space:]] ]]; then
			printf 'folder-limit: %s:%d: expected exactly three fields and a reason\n' "$file" "$number" >&2
			return 1
		fi
		if [ -z "$dir" ] || { [ "$dir" != . ] && [[ "/$dir/" == *//* || "/$dir/" == */./* || "/$dir/" == */../* ]]; }; then
			printf 'folder-limit: %s:%d: use a relative folder without ./, ../ or a trailing slash (root: .)\n' "$file" "$number" >&2
			return 1
		fi
		# Bound the decimal before shell arithmetic; reject octal and overflow.
		if [[ ! "$cap" =~ ^[1-9][0-9]{0,8}$ ]] || [ "$cap" -le 20 ]; then
			printf 'folder-limit: %s:%d: ceiling must be a decimal integer from 21 to 999999999\n' "$file" "$number" >&2
			return 1
		fi
		if [ -n "${parsed["$dir"]:-}" ]; then
			printf 'folder-limit: %s:%d: duplicate exception for %q\n' "$file" "$number" "$dir" >&2
			return 1
		fi
		parsed["$dir"]="$cap"
	done <"$file"
}

if [ -e "$exceptions" ]; then
	load_exceptions "$exceptions"
	for dir in "${!parsed[@]}"; do
		ceilings["$dir"]="${parsed["$dir"]}"
	done
fi

# Write commands to files before consuming them: a failed git inside a process
# substitution must not look like an empty, compliant repository.
git ls-files -z >"$tmp/files"
sort -zu "$tmp/files" >"$tmp/unique-files"
while IFS= read -r -d '' file; do
	dir=.
	if [[ "$file" == */* ]]; then dir="${file%/*}"; fi
	if ignored "$dir"; then continue; fi
	counts["$dir"]=$(( ${counts["$dir"]:-0} + 1 ))
done <"$tmp/unique-files"

if [ -n "${BASE:-}" ]; then
	parsed=()
	base="$(git rev-parse --verify "${BASE}^{commit}")"
	git ls-tree --name-only "$base" -- "$exceptions" >"$tmp/base-path"
	if [ -s "$tmp/base-path" ]; then
		git show "$base:$exceptions" >"$tmp/base-exceptions"
		load_exceptions "$tmp/base-exceptions"
	fi
fi

# Include exceptions for folders that disappeared so they cannot linger forever.
{
	for dir in "${!counts[@]}" "${!ceilings[@]}"; do printf '%s\0' "$dir"; done
} | sort -zu >"$tmp/folders"
failed=0
printf 'folder\tcount\tceiling\tissue\n'
while IFS= read -r -d '' dir; do
	count="${counts["$dir"]:-0}"
	cap="${ceilings["$dir"]:-20}"
	issue=''
	if [ -n "${ceilings["$dir"]:-}" ] && [ "$count" -le 20 ]; then
		issue='dead exception: count is at most 20; remove it'
	elif [ "$count" -gt "$cap" ]; then
		issue='too many direct files'
	fi
	if [ -n "${BASE:-}" ] && [ -n "${parsed["$dir"]:-}" ] && [ "$cap" -gt "${parsed["$dir"]}" ]; then
		issue="${issue:+$issue; }ceiling increased from ${parsed["$dir"]}; it may only decrease"
	fi
	# The list in the tree is the pull request's own, so it cannot be what excuses the
	# pull request: the folder has to fit what the base commit allows as well. An
	# exception is added in a pull request of its own, before the folder outgrows the limit.
	if [ -n "${BASE:-}" ] && [ "$count" -gt "${parsed["$dir"]:-20}" ]; then
		issue="${issue:+$issue; }over what the base commit allows (${parsed["$dir"]:-20})"
	fi
	if [ -n "$issue" ]; then
		printf '%q\t%d\t%d\t%s\n' "$dir" "$count" "$cap" "$issue"
		failed=1
	fi
done <"$tmp/folders"
if [ "$failed" -ne 0 ]; then exit 1; fi
printf 'folder-limit: OK (default ceiling 20)\n'
