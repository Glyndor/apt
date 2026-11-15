#!/usr/bin/env bash
#
# Print the products the served archive was built for, one name per line.
#
# Usage: published-roster.sh
#
# The health check asks for /install/<product> for every product of the roster.
# The roster that matters is the one the served files came from: the commit of the
# last successful publish. Read from the checkout instead, a product added to
# PRODUCTS and merged after that publish is asked for before any run could have
# rendered its installer, and the check went red with a 404 on every tick until the
# next publish, for a difference nobody had to fix. This is the same lesson
# reference-installers.sh applies to the templates.
#
# The commit is learned from the last successful publish run on main and fetched by
# its SHA. When it cannot be learned or fetched (no token, the API down, a SHA that
# is not a commit, a tree without the workflow, a roster that comes back empty) the
# roster of this checkout is used, which is the strict old behaviour: the check never
# gets weaker for lack of an answer. An architecture spec ("klyradb:amd64") is not
# part of the installer path, so the name alone is printed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow=".github/workflows/publish.yml"

roster_of() { # stdin: a publish.yml
	{ grep -oE '^[[:space:]]*PRODUCTS:[[:space:]]*"[^"]*"' || true; } | head -1 | sed 's/.*"\(.*\)"/\1/' | tr ' ' '\n' | sed 's/:.*//' | { grep -v '^$' || true; }
}

head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
sha="$(gh run list --workflow publish.yml --branch main --status success --limit 1 \
	--json headSha --jq '.[0].headSha // empty' 2>/dev/null || true)"
if [ -z "$head" ] || ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
	sha=""
fi

roster=""
if [ -n "$sha" ] && [ "$sha" != "$head" ]; then
	if git -C "$root" fetch --no-tags --depth=1 origin "$sha" >/dev/null 2>&1 \
		&& published="$(git -C "$root" show "$sha:$workflow" 2>/dev/null)"; then
		# The commit was fetched and its workflow read. If no roster comes out of it,
		# the way PRODUCTS is written changed, and the checkout cannot stand in for
		# it: that is the list this script exists to avoid. Stop and say so.
		roster="$(roster_of <<<"$published" || true)"
		if [ -z "$roster" ]; then
			echo "::error::the published commit ${sha:0:7} has no PRODUCTS list this script can read in $workflow; this check cannot tell which installers to ask for" >&2
			exit 1
		fi
		echo "roster: read from the published commit ${sha:0:7}" >&2
	else
		echo "roster: published commit ${sha:0:7} is not usable; using this checkout" >&2
	fi
fi
if [ -z "$roster" ]; then
	roster="$(roster_of < "$root/$workflow" 2>/dev/null || true)"
fi
if [ -z "$roster" ]; then
	echo "::error::no PRODUCTS list found in $workflow; this check cannot tell which installers to ask for" >&2
	exit 1
fi
# The names become installer paths and shell words in the consumer, so only plain
# product names go through.
while IFS= read -r name; do
	if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
		echo "::error::the roster names '$name', which is not a plain product name" >&2
		exit 1
	fi
done <<<"$roster"
printf '%s\n' "$roster"
