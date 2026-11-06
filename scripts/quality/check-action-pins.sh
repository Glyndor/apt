#!/usr/bin/env bash
#
# Fail when a remote `uses:` is not pinned by a commit SHA.
#
# WHY THIS EXISTS
#
# Every job in this repository reaches outside itself: actions/checkout to get
# the tree, actions/cache to keep a toolchain, actions/setup-go to build a
# linter. A `uses:` that names a tag or a branch is a promise about code that
# somebody else can change under the job, and only the owner of that repository
# can keep it. A commit SHA is the only reference that says exactly which
# bytes ran.
#
# The policy was already in force -- every reference in this repository was
# already pinned, and the org standard says "Always SHA-pinned either way" --
# but nothing checked it. dependabot.yml moves the pins it finds and the
# freshness reusable compares them with their upstream tags; neither of them
# refuses a reference that was never pinned at all. A pull request that added
# `uses: actions/checkout@v4` would have merged with the pin broken and
# nothing would have been red.
#
# WHAT COUNTS AS A REFERENCE
#
#   owner/repo@<40 hex>          a remote action or a remote reusable
#                                workflow: checked, and the only shape allowed
#   ./path                       a local action or a local reusable workflow:
#                                allowed, and out of scope, because it is this
#                                repository's own code
#   docker://image               a container: out of scope here, because a
#                                container is pinned by a digest and not by a
#                                commit
#
# The pin is the SHA. The trailing comment is the label of the release it
# names (`# v7.0.1`), kept beside it so a reader does not have to ask the
# network which release a commit is. The comment is not part of the reference
# and it is not validated: the SHA is what the runner resolves, and nothing
# here can compare a version string against a commit without asking GitHub.
# The freshness reusable asks its own question about that comment, and only
# when Dependabot has gone quiet; this check asks whether there is a pin at
# all.
#
# WHERE IT LOOKS
#
#   .github/workflows/*.yml       every workflow in this repository
#   .github/actions/**            composite actions, when that directory exists
#
# The tree is read from the working copy rather than from git, so a workflow
# that is not committed yet is still checked.
#
# Usage: check-action-pins.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
workflows="$root/.github/workflows"
actions="$root/.github/actions"

if [ ! -d "$workflows" ]; then
	echo "::error::no .github/workflows directory under $root" >&2
	exit 1
fi

# Every `uses:` value in one file, one per line, as "<line number><TAB><value>".
# The line is where the key sits, so a refusal points at the place to fix.
references_of() { # <path>
	awk '
		function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
		function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
		function indent_of(s,   n) {
			n = 0
			while (substr(s, n + 1, 1) == " " || substr(s, n + 1, 1) == "\t") n++
			return n
		}
		{
			raw = $0
			ind = indent_of(raw)
			trimmed = rtrim(ltrim(raw))

			# A block scalar owns the lines that follow it, until a line
			# at or above the key indentation. Inside one the word
			# `uses:` is text and not a key: the shell in
			# reusable-dependabot-freshness.yml greps for exactly that
			# word, so reading it as a reference would be a false red on
			# this repository today.
			if (inblock) {
				if (trimmed == "" || ind > block_indent) {
					if (block_is_uses && trimmed != "") {
						pending = (pending == "") ? trimmed : pending " " trimmed
					}
					next
				}
				if (block_is_uses) printf "%d\t%s\n", block_line, pending
				inblock = 0
				block_is_uses = 0
				pending = ""
			}

			# A comment is not a reference.
			if (trimmed ~ /^#/) next

			rest = raw
			while (match(rest, /uses["'"'"']?[[:space:]]*:/)) {
				pos = RSTART
				len = RLENGTH
				before = rtrim(substr(rest, 1, pos - 1))

				# A key sits at the start of a line, after a list dash,
				# a brace or a comma, and nothing else may come before
				# it. That is what keeps a one-line `run:` whose command
				# mentions `uses:` out of the count.
				if (before != "" && before !~ /[-{,]$/) {
					rest = substr(rest, pos + len)
					continue
				}

				value = substr(rest, pos + len)
				sub(/^[ \t]+/, "", value)

				# A block scalar: the value is in the lines that follow.
				if (value ~ /^[|>][-+0-9]*([ \t]*(#.*)?)?$/) {
					inblock = 1
					block_indent = ind
					block_is_uses = 1
					block_line = NR
					pending = ""
					break
				}

				if (value ~ /^"/) {
					closing = index(substr(value, 2), "\"")
					value = (closing > 0) ? substr(value, 2, closing - 1) : substr(value, 2)
				} else if (value ~ /^'"'"'/) {
					closing = index(substr(value, 2), "'"'"'")
					value = (closing > 0) ? substr(value, 2, closing - 1) : substr(value, 2)
				} else {
					# An inline comment and the end of a flow mapping
					# both close the value.
					sub(/[ \t]+#.*$/, "", value)
					sub(/[ \t]*[,}].*$/, "", value)
					sub(/[ \t]+$/, "", value)
				}
				printf "%d\t%s\n", NR, value
				break
			}
		}
		END {
			if (inblock && block_is_uses) printf "%d\t%s\n", block_line, pending
		}
	' "$1"
}

files=0
references=0
remote=0
fail=0

while IFS= read -r -d '' file; do
	rel="${file#"$root"/}"
	files=$((files + 1))
	while IFS=$'\t' read -r line value; do
		[ -n "$value" ] || continue
		references=$((references + 1))
		case "$value" in
		./*)
			# A local action or a local reusable workflow: this
			# repository's own code, with nothing to pin.
			continue
			;;
		docker://*)
			# A container, pinned by a digest and not by a commit.
			continue
			;;
		esac
		remote=$((remote + 1))
		ref="${value##*@}"
		if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
			continue
		fi
		case "$value" in
		*@*) detail="it is pinned to \`$ref\`" ;;
		*) detail="it carries no pin" ;;
		esac
		echo "::error file=$rel::$rel:$line: \`uses: $value\` is not pinned by a commit SHA: $detail. Pin it to the 40-character SHA of the commit and keep the release in a trailing comment (# vX.Y.Z)." >&2
		fail=1
	done < <(references_of "$file")
done < <(
	{
		find "$workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0
		if [ -d "$actions" ]; then
			find "$actions" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0
		fi
	} | LC_ALL=C sort -z
)

# A checker that inspected nothing prints the same success line as one that
# inspected everything, so refuse to be that.
if [ "$files" -eq 0 ]; then
	echo "::error::no workflow file was checked under $workflows; the walk is empty or broken" >&2
	exit 1
fi

if [ "$fail" -ne 0 ]; then
	echo "Some remote action reference is not pinned by a commit SHA." >&2
	exit 1
fi

echo "action pins: $references reference(s) examined in $files file(s); the $remote remote one(s) are pinned by a 40-character SHA."
