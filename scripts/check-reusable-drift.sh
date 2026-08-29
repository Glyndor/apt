#!/usr/bin/env bash
#
# Fail when this repository's copy of a reusable workflow has drifted apart from
# the copies carried by the sibling channel repositories.
#
# The three channel repositories each carry their own copy of the same seven
# reusable workflows. That duplication is deliberate: it keeps every repository
# in the publication path self-contained, so no outside repository can change
# what a release does. Nothing, however, noticed when the copies stopped
# agreeing. Until this script existed, the only thing keeping them in step was
# somebody remembering to apply a fix three times, which is care rather than a
# mechanism, and care does not survive a busy week.
#
# HOW THE COMPARISON IS MADE, and why it is not a byte comparison:
#
#   Each copy's comments describe its own repository, so the prose legitimately
#   differs -- dco.yml, pr-hygiene.yml and workflow-lint.yml already differ in
#   comments only, and the seven reusables are byte-identical today. Comparing
#   bytes would therefore turn every honest, repository-specific comment edit
#   into a red check, and a gate that goes red for a correct change is a gate
#   people learn to click past. So comment-only lines and blank lines are
#   removed from both sides before the diff: a comment edit passes, a change to
#   a `run:` block, an input default or a permission does not.
#
# WHERE THE SIBLING COPIES ARE READ FROM:
#
#   Over HTTPS from raw.githubusercontent.com. The repositories are public, so
#   this needs no token, no secret and no second checkout -- which matters,
#   because handing this check a token would give a drift reporter write reach it
#   has no business having.
#
# THREE OUTCOMES, KEPT DISTINCT ON PURPOSE:
#
#   drift            a compared file's logic differs; the diff is printed
#   fetch failure    GitHub could not be reached, or answered with nothing.
#                    This is NOT reported as drift. Conflating an unreachable
#                    network with a real disagreement teaches people that a red
#                    check means "try again later", which is exactly the habit
#                    that lets a genuine one through.
#   nothing compared refuse to pass having inspected nothing (see the bottom)
#
# Usage: check-reusable-drift.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

# The other two channel repositories. A fourth channel is one line here, and
# that line is the only edit needed. Each repository's own copy of this script
# names the other two, never itself.
SIBLINGS=(
	Glyndor/homebrew-tap
	Glyndor/scoop-bucket
)

# The reusable workflows that all three repositories are expected to carry
# identically. Files outside this list are each repository's own business.
REUSABLES=(
	reusable-dco.yml
	reusable-dependabot-freshness.yml
	reusable-empty-diff.yml
	reusable-line-limit.yml
	reusable-schedule-freshness.yml
	reusable-shell-ci.yml
	reusable-workflow-lint.yml
)

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
workflows="$root/.github/workflows"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Reduce a workflow to the lines that decide what it does: drop lines whose
# first non-space character starts a comment, drop blank lines, and drop
# trailing whitespace so an invisible byte cannot masquerade as drift.
strip_prose() { # $1=file
	sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^$/d' "$1"
}

compared=0
drifted=0
unreachable=0
absent=0

for sibling in "${SIBLINGS[@]}"; do
	for name in "${REUSABLES[@]}"; do
		mine="$workflows/$name"
		if [ ! -f "$mine" ]; then
			echo "::error::$name is not present in $workflows; this repository should carry its own copy" >&2
			absent=1
			continue
		fi

		url="https://raw.githubusercontent.com/$sibling/main/.github/workflows/$name"

		if ! curl -fsSL "$url" > "$tmp/remote" 2>"$tmp/curl.err"; then
			echo "::error::could not fetch $name from $sibling: the request to GitHub failed" >&2
			echo "  $url" >&2
			if [ -s "$tmp/curl.err" ]; then
				sed 's/^/  curl: /' "$tmp/curl.err" >&2
			fi
			echo "  This is a fetch failure, not drift: nothing is known about whether $name agrees." >&2
			unreachable=1
			continue
		fi

		if [ ! -s "$tmp/remote" ]; then
			echo "::error::$sibling answered with an empty body for $name" >&2
			echo "  $url" >&2
			echo "  This is a fetch failure, not drift: an empty file cannot be compared." >&2
			unreachable=1
			continue
		fi

		strip_prose "$mine" > "$tmp/mine.stripped"
		strip_prose "$tmp/remote" > "$tmp/remote.stripped"
		compared=$((compared + 1))

		if ! diff -u \
			--label "this repository: .github/workflows/$name" \
			--label "$sibling: .github/workflows/$name" \
			"$tmp/mine.stripped" "$tmp/remote.stripped" > "$tmp/diff"; then
			echo "::error file=.github/workflows/$name::$name has drifted from $sibling" >&2
			echo "  the difference is in the logic, not in the comments:" >&2
			sed 's/^/  /' "$tmp/diff" >&2
			drifted=$((drifted + 1))
		fi
	done
done

# A checker that inspected nothing prints the same success line as one that
# inspected everything, so refuse to be that. This has happened here before:
# line-limit reported every file within the limit on every pull request while
# never opening a workflow, because `yml` was absent from its extension list.
if [ "$compared" -eq 0 ]; then
	echo "::error::no reusable workflow was compared; the sibling list, the file list, or every fetch is broken" >&2
	exit 1
fi

if [ "$unreachable" -ne 0 ] || [ "$absent" -ne 0 ]; then
	echo "Compared $compared reusable workflow copy(ies), but some could not be read; see the errors above." >&2
	exit 1
fi

if [ "$drifted" -ne 0 ]; then
	echo "$drifted of $compared compared reusable workflow copy(ies) have drifted." >&2
	echo "Apply the same change in every channel repository, or record in the pull request why they now differ." >&2
	exit 1
fi

echo "compared $compared reusable workflow copy(ies) against ${#SIBLINGS[@]} sibling repository(ies); the logic agrees."
