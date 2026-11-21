#!/usr/bin/env bash
#
# Every curl a workflow runs is bounded the way the curl calls under scripts/ are:
# https only (and no redirect to anything else), a connect timeout, a deadline and
# a size cap.
#
# network-calls-are-bounded.test.sh reads scripts/ only. The workflows download the
# release tarballs of shellcheck and actionlint themselves, and four of those calls had
# none of the flags: the tarball is checked against a pinned sha256 before anything
# runs it, so integrity was never open, but a transfer with no deadline holds the
# runner until the job timeout, and a redirect without --proto-redir =https can leave
# TLS. A rule that reads one tree leaves the other to be forgotten, which is how it
# happened.
#
# A curl is a line that holds the word `curl` followed by a space and is not a YAML
# comment. Every flag has to be on that physical line, the same rule the scripts
# are held to: a call that continues on the next line would otherwise pass for
# flags nobody can see together. The values are not pinned, only that each flag has
# one, so moving a cap is not a change to this file.
#
# The checker is shown refusing each missing flag, a wrong protocol and a flag that
# sits on a continuation line before it reads the live workflows, and a scan that
# found no curl at all is a failure: a checker that inspected nothing has not
# inspected the workflows.
#
# Requires: python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
# The reusable workflows, the copies the three channels share. The planted ones below are
# named like a reusable workflow so that either glob reads them.
GLOB='reusable-*.yml'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# One line per missing flag: "<file>:<line>: curl is missing <flag>", then
# "curls <n>". Exit 1 when a flag is missing, or when no curl was found.
audit() { # $1=workflows dir
	python3 -I - "$1" "$GLOB" <<'PY'
import fnmatch
import os
import re
import sys

CURL = re.compile(r"(?:^|[^A-Za-z0-9_/.-])curl\s")
FLAGS = (
    ("--proto =https", re.compile(r"(?:^|\s)--proto\s+=https(?:\s|$)")),
    ("--proto-redir =https", re.compile(r"(?:^|\s)--proto-redir\s+=https(?:\s|$)")),
    ("--connect-timeout", re.compile(r"(?:^|\s)--connect-timeout\s+[0-9$]")),
    ("--max-time", re.compile(r"(?:^|\s)--max-time\s+[0-9$]")),
    ("--max-filesize", re.compile(r"(?:^|\s)--max-filesize\s+[0-9$]")),
)

root, glob = sys.argv[1], sys.argv[2]
bad = 0
curls = 0
for name in sorted(os.listdir(root)):
    if not fnmatch.fnmatch(name, glob):
        continue
    with open(os.path.join(root, name), encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if line.lstrip().startswith("#") or not CURL.search(line):
                continue
            curls += 1
            for flag, pattern in FLAGS:
                if not pattern.search(line):
                    bad += 1
                    print("%s:%d: curl is missing %s" % (name, number, flag))
if curls == 0:
    print("no curl was found")
    bad += 1
print("curls %d" % curls)
sys.exit(1 if bad else 0)
PY
}

# shellcheck disable=SC2016 # the call is text for a workflow, not run here
GOOD='curl -sSfL --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 --max-filesize 16777216 -o "$f" "$url"'

plant() { # <name> <the line a step runs>
	mkdir -p "$WORK/$1"
	printf 'jobs:\n  j:\n    steps:\n      - run: |\n          %s\n' "$2" > "$WORK/$1/reusable-w.yml"
}

# --- the accepted case, then each way of getting it wrong --------------------------
plant good "$GOOD"
rc=0; out="$(audit "$WORK/good")" || rc=$?
check "a curl with every flag on its line is accepted" "0" "$rc"
check "and the scan counted it" "curls 1" "$out"

# <name the report gives>|<text removed from the good call>
while IFS='|' read -r named removed; do
	plant "without$named" "${GOOD/ $removed/}"
	rc=0; out="$(audit "$WORK/without$named")" || rc=$?
	check "a curl without $named is refused" "1" "$rc"
	check "and the refusal names $named on line 5 and nothing else" "reusable-w.yml:5: curl is missing $named
curls 1" "$out"
done <<'FLAGS'
--proto =https|--proto =https
--proto-redir =https|--proto-redir =https
--connect-timeout|--connect-timeout 10
--max-time|--max-time 120
--max-filesize|--max-filesize 16777216
FLAGS

# A flag with no value bounds nothing: the next word is another flag.
while IFS='|' read -r named bare; do
	plant "bare$named" "${GOOD/ $bare/ $named}"
	rc=0; out="$(audit "$WORK/bare$named")" || rc=$?
	check "a curl whose $named has no value is refused" "1" "$rc"
	check "and the refusal names $named on line 5 and nothing else" "reusable-w.yml:5: curl is missing $named
curls 1" "$out"
done <<'FLAGS'
--connect-timeout|--connect-timeout 10
--max-time|--max-time 120
--max-filesize|--max-filesize 16777216
FLAGS

plant http "${GOOD/--proto =https/--proto =http}"
rc=0; out="$(audit "$WORK/http")" || rc=$?
check "a curl that allows plain http is refused" "1" "$rc"
check "and the refusal names the protocol flag" "reusable-w.yml:5: curl is missing --proto =https
curls 1" "$out"

mkdir -p "$WORK/continued"
# shellcheck disable=SC2016 # the call is text for a workflow, not run here
printf 'jobs:\n  j:\n    steps:\n      - run: |\n          curl -sSfL -o "$f" \\\n            --proto =https --proto-redir =https --connect-timeout 10 \\\n            --max-time 120 --max-filesize 16777216 "$url"\n' > "$WORK/continued/reusable-w.yml"
rc=0; out="$(audit "$WORK/continued")" || rc=$?
check "flags that sit on a continuation line do not count" "1" "$rc"
check "and all five are reported against the line that starts the call" "5" "$(printf '%s\n' "$out" | grep -c '^reusable-w.yml:5: curl is missing ')"

mkdir -p "$WORK/comment"
# shellcheck disable=SC2016 # the call is text for a workflow, not run here
printf '# curl -sSfL "$url" was the old call\njobs:\n  j:\n    steps:\n      - run: |\n          %s\n          # curl "$url" again\n' "$GOOD" > "$WORK/comment/reusable-w.yml"
rc=0; out="$(audit "$WORK/comment")" || rc=$?
check "a curl named in a comment is not a call" "0" "$rc"
check "and only the real call was counted" "curls 1" "$out"

mkdir -p "$WORK/none"
printf 'jobs:\n  j:\n    steps:\n      - run: echo hi\n' > "$WORK/none/reusable-w.yml"
rc=0; out="$(audit "$WORK/none")" || rc=$?
check "a tree with no curl at all is not a pass" "1" "$rc"
check "and says that no curl was found" "1" "$(printf '%s\n' "$out" | grep -c '^no curl was found$')"

# --- the live workflows ---------------------------------------------------------------
rc=0; out="$(audit "$HERE/.github/workflows")" || rc=$?
check "every curl in the workflows is bounded" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/        /'
check "and the scan found the calls" "1" "$(printf '%s\n' "$out" | grep -cE '^curls [1-9][0-9]*$')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
