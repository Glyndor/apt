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
# regular expression per line, each with a comment saying why. An expression is
# compared with the path of a changed file alone, never with a line of it. The list is read
# from <base>, the commit the change merges into, never from <head>: a change
# that listed its own paths would switch the scan off for them, so an entry takes
# effect from the pull request after the one that adds it. An expression that does
# not compile, or that matches every path, fails the scan instead of weakening it.
#
# Where the lines come from. The paths are the ones git lists for the range, and the
# lines of each are read from a diff of that one path, so what a file contains can
# never name another file: a line of added text that looks like a diff header is
# only text. A path with a control character in it is refused, because no record
# of it could be told from two. The diffs ignore what the tree under review says
# about how to show a file (`.gitattributes`, a textconv or an external diff), and a
# changed file that git shows as binary, or shows no change for although its
# content changed, fails the scan: a file nobody can read is not a clean one.
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
# the base commit. A missing file is an empty list; a file that cannot be read, an
# expression that does not compile, or one that matches every path is a failure.
allow_args=()
if git cat-file -e "$base:.secret-scan-allow" 2>/dev/null; then
	allow="$(git show "$base:.secret-scan-allow")" \
		|| { echo "::error::could not read .secret-scan-allow at $base" >&2; exit 1; }
	while IFS= read -r expr; do
		[ -n "$expr" ] || continue
		rc=0; printf '' | grep -qE -- "$expr" || rc=$?
		[ "$rc" -le 1 ] \
			|| { echo "::error::.secret-scan-allow: not a regular expression: $expr" >&2; exit 1; }
		# One that matches a path no repository holds would excuse every file.
		! printf '%s\n' 'no-such-path-in-any-repository' | grep -qE -- "^($expr)" \
			|| { echo "::error::.secret-scan-allow: matches every path, which would switch the scan off: $expr" >&2; exit 1; }
		allow_args+=(-e "^($expr)")
	done < <(printf '%s\n' "$allow" | grep -vE '^[[:space:]]*(#|$)' || true)
fi

path_allowed() { # <path>
	[ "${#allow_args[@]}" -gt 0 ] || return 1
	local rc=0
	printf '%s\n' "$1" | grep -qE "${allow_args[@]}" || rc=$?
	[ "$rc" -le 1 ] || { echo "::error::could not apply .secret-scan-allow" >&2; exit 1; }
	[ "$rc" -eq 0 ]
}

# The changed files, on their own: inside a pipeline the failure of this call would
# be hidden, and a range that cannot be read would pass as an empty one. Each record
# is the metadata git prints for a file and then its path, both ending in a NUL.
git_diff --raw -z --no-abbrev --diff-filter=ACMRT "$base...$head" > "$work/raw" \
	|| { echo "::error::could not diff $base...$head" >&2; exit 1; }

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
	git_diff -U0 "$base...$head" -- "$path" > "$work/file.diff" \
		|| { echo "::error::could not diff $path" >&2; exit 1; }
	if grep -aqE '^(Binary files .* differ|GIT binary patch)$' "$work/file.diff"; then
		echo "::error::git shows $path as binary, so the lines it adds were not scanned" >&2
		exit 1
	fi
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
