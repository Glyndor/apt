#!/usr/bin/env bash
#
# The shape of the publish job: which steps publish.yml declares, in what
# order they have to run, how the cache is purged, and whether the read-back
# fits in the job that carries it.
#
# publish.yml assembles the signed archive and ships it to R2 daily. Nothing
# tested it, and several of its steps are only correct in one order. Reversing
# any of them produces a run that reports success while serving something wrong,
# which is the failure mode with no alarm attached.
#
# This file reads the workflow rather than running it -- a real publish needs R2
# and Cloudflare credentials -- and asserts the order in which the steps appear.
# The three responsibilities that needed a behaviour of their own live in
# sibling files:
#
#   tests/publication/publish/publish-workflow-sync.test.sh        the three-pass sync policy
#   tests/publication/publish/publish-workflow-assets.test.sh      the download and asset selection
#   tests/publication/publish/publish-workflow-bootstrap.test.sh   the keyring signature
#
# It compares line numbers rather than parsing YAML, for two reasons. The shell
# test job does not install PyYAML, so a parser here would fail on the runner
# and pass on a developer machine. And the workflow has exactly one job, which
# the first case checks, so document order and execution order are the same
# thing. If a second job with steps is ever added, that case goes red and this
# reasoning has to be revisited rather than silently becoming wrong.
#
# Requires: nothing beyond coreutils, grep and python3.
set -u

cd "$(dirname "$0")/../../.." || exit 1
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

# --- the purge is by URL, never the whole zone ------------------------------
#
# apt.glyndor.net is a subdomain of a shared zone, so purge_everything would
# flush glyndor.net as well. The behaviour lives in the script, not here: the
# workflow only mentions the term in the comment explaining why it is avoided,
# so asserting against the workflow would be asserting against prose.
check "the purge script never asks for purge_everything" "0" \
	"$(grep -v '^[[:space:]]*#' scripts/publish/purge-cache.sh | grep -c 'purge_everything')"

check "and the workflow purges through that script" "1" \
	"$(grep -c '\./scripts/publish/purge-cache\.sh' "$WF")"

# --- the budget has to fit inside the job that carries it -------------------
#
# The read-back retries, and until 2026-09-08 nothing bounded what those
# retries could cost: against a peer that accepts a connection and never
# answers, one fetch burned --max-time times curl's own retries. Measured that
# day, four attempts and 18.0s at --max-time 3, which is 1800s at the 300 the
# script used to carry, against a job allowed 900s. The job was cancelled
# and the operator read a cancellation instead of which file was wrong.
#
# So the script takes a budget, and it is passed from HERE rather than
# defaulted, so that it sits next to the timeout it has to respect. Two numbers
# in two files is how they drift, which is the defect this repository keeps
# finding; this reads both out of the same file and requires the relationship
# rather than trusting whoever edits one of them next.
budget="$(grep -oE 'verify-published\.sh.*[0-9]+ [0-9]+ [0-9]+' "$WF" \
	| grep -oE '[0-9]+$' | head -1)"
if [ -z "$budget" ]; then
	budget="$(grep -A3 'verify-published\.sh' "$WF" | grep -oE '^[[:space:]]+keyring/[^ ]+ [0-9]+ [0-9]+ [0-9]+' | grep -oE '[0-9]+$' | head -1)"
fi
timeout_min="$(grep -oE 'timeout-minutes: [0-9]+' "$WF" | grep -oE '[0-9]+' | head -1)"
check "the read-back is given an explicit budget" "1" \
	"$([ -n "$budget" ] && echo 1 || echo 0)"
check "and the job declares a timeout to fit it in" "1" \
	"$([ -n "$timeout_min" ] && echo 1 || echo 0)"
# Comfortably inside, not merely inside: the budget bounds the retries and the
# job also has to run everything before them and print the diagnosis after.
check "and the budget leaves at least a third of the job outside itself" "1" \
	"$([ -n "$budget" ] && [ -n "$timeout_min" ] && [ "$budget" -le $(( timeout_min * 60 * 2 / 3 )) ] && echo 1 || echo 0)"

# The purge is bounded too, and for the same reason. Its curl multiplied the
# per-attempt deadline by its own retries: one hung purge request was four
# attempts of --max-time 300 plus the delays between them, so a single
# request could cost more than the whole job. The job was then cancelled and
# the operator read "cancelled after 15 minutes" instead of which group of
# URLs was not purged.
#
# It is read out of the invocation, not out of the script's default, for the
# reason the read-back's is: two numbers in two files drift.
purge_budget="$(grep -E '^[[:space:]]*\./scripts/publish/purge-cache\.sh' "$WF" \
	| grep -oE '[0-9]+$' | head -1)"
check "the purge is given an explicit budget" "1" \
	"$([ -n "$purge_budget" ] && echo 1 || echo 0)"

# And the two budgets together have to fit in the job that carries them. The
# purge runs first and the read-back after it, and the read-back's own budget
# is most of the job, so the two cannot each be checked against the timeout
# on their own: what has to fit is their sum.
#
# The reserve is two minutes for everything the job does around them -- the
# download, the build, the sync -- and for the diagnosis each of them prints
# when it runs out of time. Measured: the whole job takes 31 to 50 seconds
# today.
check "the two budgets together leave room inside the job's timeout" "1" \
	"$([ -n "$purge_budget" ] && [ -n "$budget" ] && [ -n "$timeout_min" ] && \
	   [ $(( purge_budget + budget + 120 )) -le $(( timeout_min * 60 )) ] && echo 1 || echo 0)"

# --- nothing opens a downloaded package before its signature is verified ----
#
# The release assets are chosen by whoever can publish a product release, and
# this job later holds the archive signing key and the bucket credentials, so a
# package parser must not see a downloaded .deb before a release key vouched
# for its bytes. verify-debs.sh keeps that order inside itself; this keeps it
# across the job. Every step before the one that runs verify-debs.sh is read,
# with every script it runs and every script those name, and none may run
# dpkg-deb or a dpkg mode that reads an archive. The steps and scripts are
# found by reading them, not from a list, so a new step or a new script call
# is checked the day it is added.
#
# Then the same check over two copies of the workflow: the release-order step
# moved back before the verification, which is how this workflow was until
# 2026-11-21 (check-release-order.sh reads each .deb's control fields), and a
# dpkg-deb planted in the download step. Both must be reported, so the check is
# shown to see a script call and a direct one.
opens_before_verify() { # <workflow> -> what opens a package early, one per line
	python3 -I - "$1" "$PWD" <<'PY'
import os
import re
import sys

import yaml

workflow, root = sys.argv[1], sys.argv[2]
OPENS = re.compile(r"\bdpkg-deb\b|\bdpkg\b[^\n]*\s(-[IcefxX]|--(info|contents|field|extract|fsys-tarfile|control|install))\b")
SCRIPT = re.compile(r"(?:\./)?((?:scripts|keyring/upgrade)/[\w./-]+\.sh|[\w-]+\.sh)\b")
scripts = {}
for top in ("scripts", "keyring/upgrade"):
    for dirpath, _, names in os.walk(os.path.join(root, top)):
        for name in names:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            scripts.setdefault(name, rel)
            scripts[rel] = rel


def code(text):
    return [l for l in text.splitlines() if not l.strip().startswith("#")]


def reached(text, seen):
    for line in code(text):
        for match in SCRIPT.finditer(line):
            rel = scripts.get(match.group(1)) or scripts.get(os.path.basename(match.group(1)))
            if rel and rel not in seen:
                seen.add(rel)
                reached(open(os.path.join(root, rel), encoding="utf-8").read(), seen)
    return seen


steps = yaml.safe_load(open(workflow))["jobs"]["publish"]["steps"]
gate = next(i for i, s in enumerate(steps)
            if any("scripts/verify/verify-debs.sh" in l for l in code(s.get("run", ""))))
for step in steps[:gate]:
    body = step.get("run", "")
    name = step.get("name", step.get("uses", "?"))
    if any(OPENS.search(l) for l in code(body)):
        print(f"{name}: the step itself")
    for rel in sorted(reached(body, set())):
        if any(OPENS.search(l) for l in code(open(os.path.join(root, rel), encoding="utf-8").read())):
            print(f"{name}: {rel}")
PY
}

check "no step before the signature check opens a package, itself or through a script" "" \
	"$(opens_before_verify "$WF")"

WORK_OB="$(mktemp -d)"
python3 -I - "$WF" "$WORK_OB/order-first.yml" "$WORK_OB/planted.yml" <<'PY'
import sys
text = open(sys.argv[1]).read()
order = text.index("      - name: Refuse a release older than the one served\n")
end = text.index("      - name: Gather the verified packages for the build\n")
verify = text.index("      - name: Verify product .deb release signatures\n")
assert verify < order < end
moved = text[:verify] + text[order:end] + text[verify:order] + text[end:]
open(sys.argv[2], "w").write(moved)
old = '          echo "collected $count product package(s)"\n'
assert text.count(old) == 1
open(sys.argv[3], "w").write(text.replace(old, '          dpkg-deb -f debs/podup/x.deb Package || true\n' + old))
PY
check "the control: the release-order step before the verification is reported, through its script" "1" \
	"$(opens_before_verify "$WORK_OB/order-first.yml" | grep -c '^Refuse a release older than the one served: scripts/verify/check-release-order.sh$')"
check "the control: a dpkg-deb in an earlier step is reported" "1" \
	"$(opens_before_verify "$WORK_OB/planted.yml" | grep -c '^Download the latest .deb of each product: the step itself$')"
rm -rf "$WORK_OB"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
