#!/usr/bin/env bash
#
# Refuse a pull request that adds something shaped like a credential.
#
# Looks only at the lines <base>..<head> adds, so an old file is never a reason to
# fail. It reports file and line and the name of the pattern, never the value: a
# CI log of a public repository is public too.
#
# What it knows: private key blocks (a PEM file, or a PEM with its body inside a
# string; code that only writes or checks the header line is not one), the token formats of AWS, GitHub, GitLab,
# Slack, npm, Google and OpenAI, JWTs, and an assignment of a long value to a name
# that says secret, token, password or key. The last one is what catches a
# credential with a format of its own, such as a signing key in base64. A line whose
# text carries the word secret-scan:allow is skipped, for a value that is public on
# purpose; say why next to it. A file cannot carry a comment, so a repository that
# keeps throwaway test keys lists the paths in .secret-scan-allow at its root, one
# literal path per line, each with a comment saying why. A line names one file, or a
# directory when it ends in `/`, and then every file under it; it is compared with the
# path of a changed file alone, never with a line of it, and by string equality or
# prefix, not by pattern. There are no wildcards and no expressions, because whether
# an expression matches every path but one cannot be decided by reading it. A line
# with a wildcard or an expression character (`* ? [ ^ $ | ( \`), one that starts with
# `/` or `./`, and one that holds `..` fail the scan, naming the line. The list is read
# from <base>, the commit the change merges into, never from <head>: a change
# that listed its own paths would switch the scan off for them, so an entry takes
# effect from the pull request after the one that adds it.
#
# Where the lines come from. The paths are the ones git lists for the range, and the
# lines of each are read from a diff of that one path, so what a file contains can
# never name another file: a line of added text that looks like a diff header is
# only text. A path with a control character in it is refused, because no record
# of it could be told from two. The diffs ignore what the tree under review says
# about how to show a file (`.gitattributes`, a textconv or an external diff), and
# they ask git for text with --text. A binary file is therefore read like any other:
# the bytes it adds are split into lines and checked against the same patterns, so a
# credential inside one is found, and an image that holds none passes. Git never prints
# "Binary files differ" under --text, so there is no separate refusal for a binary. What
# it can still print is nothing at all for a file whose content changed (an empty file
# is the one honest case, and passes: it has no line to read); that fails the scan,
# since a file git shows no change for is a file nobody read.
# A file whose content the base already holds, as a move or a copy leaves it, adds
# nothing to the history and is not read again.
#
# This is a filter for the mistake, not a vault: GitHub's push protection and
# secret scanning remain the other half.
#
# Usage: check-secrets.sh <base> <head>

set -euo pipefail
export LC_ALL=C

base="${1:?base}"; head="${2:?head}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git_diff() { # <git diff arguments>
	git --literal-pathspecs diff --no-color --no-renames --text --no-textconv --no-ext-diff "$@"
}

# Paths the repository declares as holding throwaway keys on purpose, read from
# the base commit, one literal path per line. A missing file is an empty list; a file
# that cannot be read, or a line that is not a literal path, is a failure: a pattern
# cannot be judged by reading it (`^[^z]` and `.*[^a]$` match everything but one
# name), so none is accepted. A line is a path relative to the root of the repository
# and holds no wildcard and no expression character, does not start with `/` or `./`
# and has no `..` in it.
allow_paths=()
if git cat-file -e "$base:.secret-scan-allow" 2>/dev/null; then
	allow="$(git show "$base:.secret-scan-allow")" \
		|| { echo "::error::could not read .secret-scan-allow at $base" >&2; exit 1; }
	while IFS= read -r numbered; do
		n="${numbered%%:*}"; entry="${numbered#*:}"
		case "$entry" in
			*'*'* | *'?'* | *'['* | *'^'* | *'$'* | *'|'* | *'('* | *\\*)
				echo "::error::.secret-scan-allow line $n: holds a wildcard or an expression character; a line is a literal path: $entry" >&2
				exit 1
				;;
			/* | ./*)
				echo "::error::.secret-scan-allow line $n: starts with / or ./; a path is relative to the root of the repository: $entry" >&2
				exit 1
				;;
			*..*)
				echo "::error::.secret-scan-allow line $n: holds ..; a path stays under the root of the repository: $entry" >&2
				exit 1
				;;
		esac
		allow_paths+=("$entry")
	done < <(printf '%s\n' "$allow" | grep -nvE '^[[:space:]]*(#|$)' || true)
fi

# An entry excuses the file it names, or, when it ends in `/`, every file under that
# directory. The comparison is of strings: equality or a prefix, never a pattern.
path_allowed() { # <path>
	local entry
	for entry in ${allow_paths[@]+"${allow_paths[@]}"}; do
		if [ "$1" = "$entry" ]; then return 0; fi
		case "$entry" in
			*/) if [ "${1#"$entry"}" != "$1" ]; then return 0; fi ;;
		esac
	done
	return 1
}

# The changed files, on their own: inside a pipeline the failure of this call would
# be hidden, and a range that cannot be read would pass as an empty one. Each record
# is the metadata git prints for a file and then its path, both ending in a NUL.
git_diff --raw -z --no-abbrev --diff-filter=ACMRT "$base...$head" > "$work/raw" \
	|| { echo "::error::could not diff $base...$head" >&2; exit 1; }

# The contents the base already holds. A file whose content is among them adds nothing
# to the history: a move or a copy shows up as an added file, and its every line would
# be read as new.
git ls-tree -r "$base" > "$work/tree" \
	|| { echo "::error::could not list the files of $base" >&2; exit 1; }
cut -f1 "$work/tree" | awk '{ print $3 }' | sort -u > "$work/base-blobs"

# One "path TAB line TAB text" per added line. awk only parses the diff of one file;
# the path reaches it from the environment, and a line counts only inside a hunk.
: > "$work/added"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
	read -r _ _ old_blob new_blob _ <<< "${meta#:}"
	case "$path" in
		*[[:cntrl:]]*)
			echo "::error::a changed file has a control character in its name ($(printf '%q' "$path")); the lines it adds cannot be told from the lines of another file" >&2
			exit 1
			;;
	esac
	if path_allowed "$path"; then continue; fi
	if grep -qxF -- "$new_blob" "$work/base-blobs"; then continue; fi
	git_diff -U0 "$base...$head" -- "$path" > "$work/file.diff" \
		|| { echo "::error::could not diff $path" >&2; exit 1; }
	hunks="$(grep -ac '^@@ ' "$work/file.diff" || true)"
	if [ "$hunks" -eq 0 ] && [ "$old_blob" != "$new_blob" ]; then
		size="$(git cat-file -s "$new_blob")" \
			|| { echo "::error::could not read the size of $path" >&2; exit 1; }
		[ "$size" -eq 0 ] \
			|| { echo "::error::git shows no change for $path although its content changed, so the lines it adds were not scanned" >&2; exit 1; }
	fi
	P="$path" awk '
		BEGIN { file = ENVIRON["P"] }
		/^@@/ { split($3, a, ","); line = substr(a[1], 2) + 0; inhunk = 1; next }
		inhunk && /^\+/ {
			text = substr($0, 2)
			if (index(text, "secret-scan:allow") == 0) print file "\t" line "\t" text
			line++
		}
	' "$work/file.diff" >> "$work/added"
done < "$work/raw"

[ -s "$work/added" ] || { echo "no credential-shaped lines added"; exit 0; }

# The patterns read the text of a line alone. Line N of texts is line N of locs.
cut -f1,2 "$work/added" > "$work/locs"
cut -f3- "$work/added" > "$work/texts"

# The "path:line" of every line whose number arrives on stdin.
locate() {
	awk -F'\t' 'NR == FNR { want[$1]; next } FNR in want { print $1 ":" $2 }' - "$work/locs"
}

patterns=(
	'private key block|^-----BEGIN ((RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED) )?PRIVATE KEY( BLOCK)?-----[[:space:]]*$'
	'private key inside a string|-----BEGIN ((RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED) )?PRIVATE KEY( BLOCK)?-----(\\n|[[:space:]])*[A-Za-z0-9+/]{20,}'
	'AWS access key|(AKIA|ASIA)[0-9A-Z]{16}'
	'GitHub token|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}'
	'GitLab token|glpat-[A-Za-z0-9_-]{20}'
	'Slack token|xox[baprs]-[A-Za-z0-9-]{10,}'
	'npm token|npm_[A-Za-z0-9]{36}'
	'Google API key|AIza[0-9A-Za-z_-]{35}'
	'API key|sk-[A-Za-z0-9]{32,}'
	'JWT|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{10,}'
)

bad=0
report() { # <name> <path:line per matching line>
	printf '%s\n' "$2" | sed "s|\$| $1|; s|^|::error::|"
	bad=1
}

for entry in "${patterns[@]}"; do
	name="${entry%%|*}"; re="${entry#*|}"
	hits="$(grep -anE -- "$re" "$work/texts" | cut -d: -f1 | locate || true)"
	[ -z "$hits" ] || report "$name" "$hits"
done

# A credential with a format of its own is caught by the name it is assigned to. What
# excuses a match is read from the part it concerns: the words of a sample value
# (example, placeholder, fake...) in the value alone, as whole words, and the suffix of
# a name that points at something else (a path, a file, a variable) in the name alone.
# A comment that says "example" or a name that does, next to a real key, excuses nothing.
generic='(token|secret|passw(or)?d|api[_-]?key|private[_-]?key|signing[_-]?key|access[_-]?key|ed25519[_-]?key|ml[_-]?dsa[_-]?(44|65|87)?[_-]?key|credential)[a-z0-9_]*["'"'"']?[ \t]*[:=][ \t]*["'"'"']?[a-z0-9+/_=-]{32,}'
hits="$(grep -anoiE -- "$generic" "$work/texts" | awk -v sq="'" '
	{
		n = substr($0, 1, index($0, ":") - 1)
		assign = substr($0, index($0, ":") + 1)
		i = match(assign, /[:=]/)
		name = tolower(substr(assign, 1, i))
		value = tolower(substr(assign, i + 1))
		sub(/^[ \t]*/, "", value)
		if (substr(value, 1, 1) == "\"" || substr(value, 1, 1) == sq) value = substr(value, 2)
		if (name ~ /_(file|path|dir|url|name|env|var)[a-z0-9_]*[^a-z0-9_]*$/) next
		if (value ~ /(^|[^a-z0-9])(example|placeholder|dummy|fake|fixture|changeme|redacted|your)([^a-z0-9]|$)/) next
		print n
	}' | sort -un | locate || true)"
[ -z "$hits" ] || report "long value assigned to a secret-like name" "$hits"

if [ "$bad" -ne 0 ]; then
	echo "Remove the value and rotate it if it was ever real; add secret-scan:allow only for a value that is public on purpose." >&2
	exit 1
fi
echo "no credential-shaped lines added"
