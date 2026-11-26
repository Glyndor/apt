#!/usr/bin/env bash
#
# What the last publication of this archive left behind: the Date and SHA256 of the InRelease it published, from the
# artifact its own run kept. Whoever can write the bucket cannot write that.
#
#   read-publication-record.sh <out-file>
#
# Writes '<time> <sha256>', or 'none' when no run that is read has recorded one. Env: REPO (owner/name), GH_TOKEN with
# actions: read.
#
# Only a run of .github/workflows/publish.yml, on main of this repository, started by the schedule or by hand, is read:
# an artifact of the same name from another workflow, branch, fork or event is ignored. Any answer of GitHub that
# cannot be read is a failure, never 'none'.
set -euo pipefail
export LC_ALL=C

NAME="apt-published-index"
[ "$#" -eq 1 ] || { echo "::error::usage: read-publication-record.sh <out-file>" >&2; exit 2; }
out="$1"
[ -n "${REPO:-}" ] || { echo "::error::REPO is not set" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

runs="$(gh api "repos/$REPO/actions/workflows/publish.yml/runs?branch=main&per_page=50" \
	--jq '.workflow_runs[] | [(.id | tostring), .path, .head_branch, .event, (.head_repository.full_name // "")] | @tsv')" \
	|| { echo "::error::cannot list the runs of the publish; what the last one served cannot be established" >&2; exit 1; }
while IFS=$'\t' read -r id path branch event head; do
	[ -n "$id" ] || continue
	[ "$path" = .github/workflows/publish.yml ] && [ "$branch" = main ] && [ "$head" = "$REPO" ] || continue
	case "$event" in schedule | workflow_dispatch) ;; *) continue ;; esac
	[[ "$id" =~ ^[0-9]+$ ]] || { echo "::error::the list of runs names '$id', which is not a run id" >&2; exit 1; }
	count="$(gh api "repos/$REPO/actions/runs/$id/artifacts?per_page=100" \
		--jq "[.artifacts[] | select(.name == \"$NAME\" and .expired == false)] | length")" \
		|| { echo "::error::cannot list the artifacts of run $id" >&2; exit 1; }
	case "$count" in
		0) continue ;;
		1) ;;
		*) echo "::error::run $id answers '$count' artifacts named $NAME" >&2; exit 1 ;;
	esac
	gh run download "$id" --repo "$REPO" --name "$NAME" --dir "$work/found" \
		|| { echo "::error::cannot download $NAME of run $id" >&2; exit 1; }
	line="$(cat "$work/found/published-index")" || { echo "::error::$NAME of run $id holds no published-index" >&2; exit 1; }
	[[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ [0-9a-f]{64}$ ]] \
		|| { echo "::error::the record of run $id is not '<time> <sha256>'" >&2; exit 1; }
	printf '%s\n' "$line" > "$out"
	echo "run $id recorded the index it published: $line"
	exit 0
done <<< "$runs"
echo none > "$out"
echo "::notice::no run of the publish that was read has recorded the index it published; the served one has to be recent"
