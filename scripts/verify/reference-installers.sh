#!/usr/bin/env bash
#
# Render the installers the health check compares the served ones with.
#
# Usage: reference-installers.sh <out-dir> <product>...
#
# The reference has to be what the archive was built from. The publish runs once
# a day and the health check four times, so a template change merged between two
# publishes made the health check red on every tick until the next publish, for a
# difference nobody had to fix: measured on 2026-11-08, five of the last six
# scheduled runs failed this way. The generator of the last SUCCESSFUL publish
# run's commit is what produced the served files, so that is the reference.
#
# It is fetched by its SHA and rendered from a detached worktree, never from the
# host being checked. When the commit cannot be learned or fetched (no token, the
# API down, a SHA that is not a commit, a tree without the generator), the
# generator of this checkout is used instead, which is the strict old behaviour:
# the check never gets weaker for lack of an answer.
set -euo pipefail

out="${1:?usage: reference-installers.sh <out-dir> <product>...}"
shift
[ "$#" -ge 1 ] || { echo "usage: reference-installers.sh <out-dir> <product>..." >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Outside a git checkout there is nothing to fetch into: this checkout it is.
head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"

sha="$(gh run list --workflow publish.yml --status success --limit 1 \
	--json headSha --jq '.[0].headSha // empty' 2>/dev/null || true)"
if [ -z "$head" ] || ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
	sha=""
fi

tree=""
cleanup() {
	if [ -n "$tree" ]; then
		git -C "$root" worktree remove --force "$tree/src" >/dev/null 2>&1 || true
		rm -rf "$tree"
	fi
}
trap cleanup EXIT

if [ -n "$sha" ] && [ "$sha" != "$head" ]; then
	tree="$(mktemp -d)"
	if git -C "$root" fetch --no-tags --depth=1 origin "$sha" >/dev/null 2>&1 \
		&& git -C "$root" worktree add --detach "$tree/src" "$sha" >/dev/null 2>&1 \
		&& [ -x "$tree/src/scripts/build/build-installers.sh" ]; then
		echo "reference installers: generated from the published commit ${sha:0:7}"
		"$tree/src/scripts/build/build-installers.sh" "$out" "$@"
		exit 0
	fi
	echo "reference installers: published commit ${sha:0:7} is not usable; using this checkout" >&2
fi

echo "reference installers: generated from this checkout"
"$root/scripts/build/build-installers.sh" "$out" "$@"
