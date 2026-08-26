#!/usr/bin/env bash
#
# publish.yml assembles the signed archive and ships it to R2 daily. Nothing
# tested it, and several of its steps are only correct in one order. Reversing
# any of them produces a run that reports success while serving something wrong,
# which is the failure mode with no alarm attached.
#
# The test reads the workflow rather than running it -- a real publish needs R2
# and Cloudflare credentials -- and asserts the order in which the steps appear.
#
# It compares line numbers rather than parsing YAML, for two reasons. The shell
# test job does not install PyYAML, so a parser here would fail on the runner
# and pass on a developer machine. And the workflow has exactly one job, which
# the first case checks, so document order and execution order are the same
# thing. If a second job with steps is ever added, that case goes red and this
# reasoning has to be revisited rather than silently becoming wrong.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/.." || exit 1
WF=".github/workflows/publish.yml"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Line of the first step whose name contains $1, or empty. Anchored to the step
# list's indentation so a mention inside a comment cannot satisfy it -- the
# comments in this workflow discuss these steps by name at length.
step_line() { grep -n "^      - name:.*$1" "$WF" | head -1 | cut -d: -f1; }

before() { # <a> <b> -> 1 when both exist and a comes first
	[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ] && echo 1 || echo 0
}

# --- the assumption this whole file rests on --------------------------------
#
# One job means document order is execution order. Two would not.
check "publish.yml declares exactly one job" "1" \
	"$(awk '/^jobs:/{j=1;next} j && /^  [a-zA-Z_-]+:/{c++} END{print c+0}' "$WF")"

# --- the steps exist --------------------------------------------------------
verify_sigs="$(step_line 'Verify product .deb release signatures')"
build_repo="$(step_line 'Build signed apt repository')"
publish="$(step_line 'Publish to R2')"
purge="$(step_line 'Purge Cloudflare cache')"
verify_pub="$(step_line 'Verify the published archive')"

for pair in "verify_sigs:the release signatures are verified" \
            "build_repo:the signed repository is built" \
            "publish:the archive is published to R2" \
            "purge:the Cloudflare cache is purged" \
            "verify_pub:the published archive is read back"; do
	var="${pair%%:*}"; desc="${pair#*:}"
	eval "v=\$$var"
	check "there is a step where $desc" "1" "$([ -n "$v" ] && echo 1 || echo 0)"
done

# --- signatures are checked before anything is built ------------------------
#
# The archive's whole claim is that a package in it is the one its product
# released. Building first and verifying afterwards would put an unverified
# .deb into a signed index.
check "release signatures are verified before the repository is built" "1" \
	"$(before "$verify_sigs" "$build_repo")"

# --- the archive is uploaded before the cache is purged ---------------------
#
# Purging first re-caches the OLD objects, because the edge refetches on the
# next request and the new ones are not there yet.
check "the archive is uploaded before the cache is purged" "1" \
	"$(before "$publish" "$purge")"

# --- the cache is purged before the archive is read back --------------------
#
# This is the one the workflow explains at length: reading back while the edge
# still holds the previous metadata compares a fresh signature against stale
# bytes, and passes. A green run over a stale index is worse than a red one.
check "the cache is purged before the published archive is read back" "1" \
	"$(before "$purge" "$verify_pub")"

# --- the read-back is last --------------------------------------------------
check "nothing runs after the read-back" "1" \
	"$([ -n "$verify_pub" ] && \
	   [ "$(grep -c '^      - name:' "$WF")" \
	     -eq "$(grep -n '^      - name:' "$WF" | cut -d: -f1 | awk -v l="$verify_pub" '$1<=l' | wc -l)" ] \
	   && echo 1 || echo 0)"

# --- the three-pass sync ----------------------------------------------------
#
# Pass 1 uploads pool/ without deleting, pass 2 publishes the metadata, pass 3
# removes the pool entries the new metadata stopped referencing. The order is
# the invariant: deleting before the metadata is published leaves apt fetching
# a .deb that is already gone, and publishing metadata before the packages
# leaves it referencing files that have not arrived.
# Anchored to the command's own indentation. The comments in this workflow
# discuss `aws s3 sync` by name, and an unanchored grep counts those too -- it
# reported five passes where there are three.
sync_lines="$(grep -n '^          aws s3 sync' "$WF" | cut -d: -f1)"
check "the publish step syncs in three passes" "3" \
	"$(printf '%s\n' "$sync_lines" | grep -c .)"

p1="$(printf '%s\n' "$sync_lines" | sed -n 1p)"
p2="$(printf '%s\n' "$sync_lines" | sed -n 2p)"
p3="$(printf '%s\n' "$sync_lines" | sed -n 3p)"

# Read each pass's flags: from its own line up to the next pass (or the end of
# the step), so a flag cannot be attributed to the wrong invocation -- and with
# comment lines dropped. The comment introducing pass 2 says "Deliberately NOT
# --delete", which is enough to make an unfiltered range report that pass 1
# deletes. Every assertion in this file reads commands, never prose.
flags_of() { sed -n "${1},${2}p" "$WF" | grep -v '^[[:space:]]*#'; }

check "pass 1 uploads pool/ and deletes nothing" "1" \
	"$(flags_of "$p1" "$((p2 - 1))" | grep -q -- '--include "pool/\*"' && \
	   ! flags_of "$p1" "$((p2 - 1))" | grep -q -- '--delete' && echo 1 || echo 0)"

check "pass 2 publishes the metadata without --delete" "1" \
	"$(flags_of "$p2" "$((p3 - 1))" | grep -q -- '--exclude "pool/\*"' && \
	   ! flags_of "$p2" "$((p3 - 1))" | grep -q -- '--delete' && echo 1 || echo 0)"

check "pass 3 is the one that deletes, and only in pool/" "1" \
	"$(flags_of "$p3" "$((p3 + 6))" | grep -q -- '--delete' && \
	   flags_of "$p3" "$((p3 + 6))" | grep -q -- '--include "pool/\*"' && echo 1 || echo 0)"

# --- the purge is by URL, never the whole zone ------------------------------
#
# apt.glyndor.net is a subdomain of a shared zone, so purge_everything would
# flush glyndor.net as well. The behaviour lives in the script, not here: the
# workflow only mentions the term in the comment explaining why it is avoided,
# so asserting against the workflow would be asserting against prose.
check "the purge script never asks for purge_everything" "0" \
	"$(grep -v '^[[:space:]]*#' scripts/purge-cache.sh | grep -c 'purge_everything')"

check "and the workflow purges through that script" "1" \
	"$(grep -c '\./scripts/purge-cache\.sh' "$WF")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
