#!/usr/bin/env bash
#
# publish.yml judges the served index against a record the bucket cannot change, and leaves that record for the next
# publication. This holds the steps that do it to each other: where they stand, what they hand over, who may set an index
# aside and under which name the record is kept and read. Each rule is run over a copy of the workflow that breaks it.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the planted edits are text of python and of the workflow, ${{ }} and $RUNNER_TEMP as written
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/publish.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fail=$((fail + 1))
	fi
}

offences() { # <workflow>
	python3 -I - "$1" "$HERE/scripts/verify/read-publication-record.sh" <<'PY'
import re
import sys

import yaml

with open(sys.argv[1]) as handle:
    spec = yaml.safe_load(handle)
on = spec.get(True, spec.get("on"))
job = spec["jobs"]["publish"]
steps = job["steps"]
names = [s.get("name", "") for s in steps]
with open(sys.argv[2]) as handle:
    artifact = re.search(r'(?m)^NAME="([^"]+)"$', handle.read()).group(1)

dispatch = on.get("workflow_dispatch") or {}
wanted = dispatch.get("inputs", {}).get("accept_old_index", {})
if wanted.get("type") != "string" or wanted.get("default") != "":
    print("accept_old_index is not a text that is empty unless somebody writes it")
if job.get("permissions") != {"contents": "read", "actions": "read"}:
    print("the job does not hold exactly contents: read and actions: read")
order = ["Verify product .deb release signatures", "Read what the last publication recorded",
         "Refuse a release older than the one served", "Publish to R2", "Purge Cloudflare cache (mutable, fixed-name files)",
         "Record the index that was published", "Keep the record for the next publication",
         "Verify the published archive matches the signed index"]
at = [names.index(n) if n in names else -1 for n in order]
if -1 in at or at != sorted(at) or at[-1] != len(steps) - 1:
    print("the steps of the record are missing or out of order")
    sys.exit(0)
step = {n: steps[names.index(n)] for n in order}
for name in order[1:3] + order[5:7]:
    if "if" in step[name] or "continue-on-error" in step[name]:
        print(f"{name} can be skipped or fail without failing the run")
read = step["Read what the last publication recorded"]
if read.get("env") != {"GH_TOKEN": "${{ github.token }}", "REPO": "${{ github.repository }}"} \
        or read.get("run") != './scripts/verify/read-publication-record.sh "$RUNNER_TEMP/index-record"':
    print("the record is not read as the next step expects it")
judged = step["Refuse a release older than the one served"].get("env", {})
if judged.get("INDEX_RECORD") != "${{ runner.temp }}/index-record":
    print("the order check is not handed the record that was read")
if judged.get("ACCEPT_OLD_INDEX") != "${{ github.event_name == 'workflow_dispatch' && inputs.accept_old_index || '' }}":
    print("something else than a run started by hand can set an index aside")
if set(judged) != {"INDEX_RECORD", "ACCEPT_OLD_INDEX"}:
    print("the order check is given more than the record and the index to accept")
written = step["Record the index that was published"].get("run")
if written != './scripts/verify/write-publication-record.sh public/dists/stable/InRelease "$RUNNER_TEMP/published-index"':
    print("what is recorded is not the index this run published")
kept = step["Keep the record for the next publication"]
if not str(kept.get("uses", "")).startswith("actions/upload-artifact@") or kept.get("with") != {
        "name": artifact, "path": "${{ runner.temp }}/published-index/published-index", "if-no-files-found": "error",
        "retention-days": 90, "overwrite": True}:
    print("the record is not kept for 90 days under the name it is read by")
PY
}

check "the workflow reads, judges by and keeps the record" "" "$(offences "$WF")"

planted() { # <name> <python expression over the text s>
	python3 -I -c 'import sys
s = open(sys.argv[1]).read(); n = eval(sys.argv[3]); assert n != s, "the edit changed nothing"; open(sys.argv[2], "w").write(n)' \
		"$WF" "$WORK/$1.yml" "$2" || { echo "the edit of $1 did not apply"; return; }
	offences "$WORK/$1.yml"
}
check "an input that is a switch" "accept_old_index is not a text that is empty unless somebody writes it" \
	"$(planted switch 's.replace("        type: string\n        default: \"\"\n", "        type: boolean\n        default: false\n", 1)')"
check "a job that cannot read the runs" "the job does not hold exactly contents: read and actions: read" \
	"$(planted perms 's.replace("      actions: read # the record", "      # the record", 1)')"
check "a record kept after the read-back" "the steps of the record are missing or out of order" \
	"$(planted order 's.replace("      - name: Record the index that was published", "      - name: Record the index", 1)')"
check "a reading that may fail" "Read what the last publication recorded can be skipped or fail without failing the run" \
	"$(planted soft 's.replace("      - name: Read what the last publication recorded\n", "      - name: Read what the last publication recorded\n        continue-on-error: true\n", 1)')"
check "an order check that reads another file" "the order check is not handed the record that was read" \
	"$(planted other 's.replace("INDEX_RECORD: ${{ runner.temp }}/index-record", "INDEX_RECORD: /dev/null", 1)')"
check "an input a scheduled run would read" "something else than a run started by hand can set an index aside" \
	"$(planted sched 's.replace("github.event_name == '\''workflow_dispatch'\'' && inputs.accept_old_index || '\'''\''", "inputs.accept_old_index", 1)')"
check "a record of the file that was served before" "what is recorded is not the index this run published" \
	"$(planted stale 's.replace("write-publication-record.sh public/dists/stable/InRelease", "write-publication-record.sh old/InRelease", 1)')"
check "a record kept for a week" "the record is not kept for 90 days under the name it is read by" \
	"$(planted week 's.replace("          retention-days: 90\n", "          retention-days: 7\n", 1)')"
check "a record under another name" "the record is not kept for 90 days under the name it is read by" \
	"$(planted renamed 's.replace("          name: apt-published-index\n", "          name: index\n", 1)')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
