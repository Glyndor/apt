#!/usr/bin/env bash
#
# Every workflow declares the permissions of its token, and none of them writes.
#
#   workflow  each workflow file has a top-level `permissions:` mapping, `{}` when it needs
#             nothing. Without one the token gets the default of the repository or the
#             organisation, which is a setting no file here records and no pull request
#             can see change.
#   levels    a level is read, write or none; `write-all` and `read-all` are not a list.
#   writes    no workflow holds a write, and only one job does: the job that cancels the
#             other runs of a pull request that failed, which needs `actions: write` to end
#             them. Nothing else in this repository needs one: the publish job writes to R2
#             and to Cloudflare with their own credentials, and to nothing in GitHub. A job
#             that has to is the change that adds a case here saying which job and why, so a
#             write is never a line a pull request slips in.
#   secrets   a job that names `secrets.*` declares its own `permissions:` and does not
#             inherit the workflow's. It is the job that holds the signing key, the bucket
#             credentials and the purge token, and what its token can do should be written
#             where those are.
#
# Before this file the one line that makes the publish job's token read-only was read by
# nothing: deleting every `permissions:` block of every workflow failed one suite, and that
# one because it greps for an unrelated `actions: read`.
#
# Each rule runs on the real files and on copies that break it one way each, and a rule that
# cannot run prints "rule failed" so a crash is never read as no violation. Each refusal is
# asserted by what it names, and each is paired with the real files, which are clean.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1)); echo "ok    $1"
	else
		fail=$((fail + 1)); echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
	fi
}

# violations [workflow-dir]: one line per violation over every workflow file.
violations() {
	python3 -I - "${1:-$HERE/.github/workflows}" 2>&1 <<'PY' || echo "rule failed"
import glob
import os
import re
import sys

import yaml

root = sys.argv[1]
LEVELS = {"read", "write", "none"}
# `secrets.NAME` or `secrets['NAME']` as an expression names one; a file called check-secrets.sh does not.
SECRET = re.compile(r"(?<![\w.-])secrets(?:\.\w|\[)")

# The one job of this repository that holds a write, and the scope of it.
#
#   cancel-others   the job that ends the other runs of a pull request whose work has
#                   failed. Cancelling a run is `actions: write`, and the write is on that
#                   job alone: no workflow of this repository declares it at the top. The
#                   job runs no code the pull request controls: a workflow triggered by
#                   `workflow_run` runs the file of the default branch and its checkout
#                   is that branch, so the script it runs is the copy of the default
#                   branch, which
#                   tests/ci/cancel/others.test.sh holds.
ALLOWED_WRITES = {
    ("cancel-others.yml", "cancel-others"): frozenset({"actions"}),
}

files = sorted(glob.glob(os.path.join(root, "*.yml")) + glob.glob(os.path.join(root, "*.yaml")))
if not files:
    print("no workflow was found, so nothing was inspected")


def names_secrets(node):
    """True when a job names a secret anywhere: a `secrets.*` expression or a `secrets:` key."""
    if isinstance(node, dict):
        return any(k == "secrets" or names_secrets(v) for k, v in node.items())
    if isinstance(node, list):
        return any(names_secrets(v) for v in node)
    return isinstance(node, str) and SECRET.search(node) is not None


def mapping(name, where, value):
    """The scopes of a permissions value, or None after naming why it is not a list of them."""
    if not isinstance(value, dict):
        print(f"{name}: {where} grants {value}; name each permission, `{{}}` when it needs none")
        return None
    for scope, level in value.items():
        if level not in LEVELS:
            print(f"{name}: {where} holds {scope}: {level}, which is not read, write or none")
    return value


def writes(name, where, value, job=None):
    for scope, level in value.items():
        if level != "write":
            continue
        if scope in ALLOWED_WRITES.get((name, job), frozenset()):
            continue
        print(f"{name}: {where} holds {scope}: write; nothing in this repository writes to GitHub")


for path in files:
    name = os.path.basename(path)
    try:
        with open(path) as handle:
            doc = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError):
        print(f"{name}: cannot be read as a workflow, so its permissions are unknown")
        continue
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        print(f"{name}: is not a workflow, so its permissions are unknown")
        continue
    if "permissions" not in doc:
        print(f"{name}: declares no permissions for the workflow, so every job gets the default of the repository")
    else:
        top = mapping(name, "the workflow", doc["permissions"])
        if top is not None:
            writes(name, "the workflow", top)
    for job, cfg in doc["jobs"].items():
        if not isinstance(cfg, dict):
            continue
        if "permissions" in cfg:
            own = mapping(name, job, cfg["permissions"])
            if own is not None:
                writes(name, job, own, job)
        elif names_secrets(cfg):
            print(f"{name}: {job} names a secret and declares no permissions of its own")
PY
}

BAD="$(mktemp -d)"
trap 'rm -rf "$BAD"' EXIT
# fixture <file> <sed expression>: a copy of the workflows with one file changed. A change
# that does nothing is reported, so a rule is never judged against a copy that still holds.
fixture() {
	rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
	sed -i "$2" "$BAD/$1"
	if cmp -s "$BAD/$1" "$HERE/.github/workflows/$1"; then echo "FIXTURE INERT: $1 $2"; fi
}

check "every workflow declares its permissions, only the cancel job writes and a job with a secret has its own" "" "$(violations)"

fixture tests.yml '/^permissions:$/,/^  contents: read$/d'
check "a workflow with no permissions of its own is named" \
	"tests.yml: declares no permissions for the workflow, so every job gets the default of the repository" "$(violations "$BAD")"
fixture commit-hygiene.yml 's/^permissions: {}$/permissions: write-all/'
check "a workflow that grants write-all is named" \
	"commit-hygiene.yml: the workflow grants write-all; name each permission, \`{}\` when it needs none" "$(violations "$BAD")"
fixture drift.yml 's/^  contents: read$/  contents: write/'
check "a write granted to a whole workflow is named" \
	"drift.yml: the workflow holds contents: write; nothing in this repository writes to GitHub" "$(violations "$BAD")"
fixture publish.yml '/^    permissions:$/{n;s/contents: read/contents: write/}'
check "a write granted to one job is named for the job" \
	"publish.yml: publish holds contents: write; nothing in this repository writes to GitHub" "$(violations "$BAD")"
fixture publish.yml '/^    permissions:$/{n;s/contents: read/contents: admin/}'
check "a level that is not read, write or none is named" \
	"publish.yml: publish holds contents: admin, which is not read, write or none" "$(violations "$BAD")"
fixture publish.yml '/^    permissions:$/,/^      contents: read$/d; /^      actions: read/d'
check "the job that holds the secrets, left to inherit the workflow's token, is named" \
	"publish.yml: publish names a secret and declares no permissions of its own" "$(violations "$BAD")"
fixture publish.yml 's/^    permissions:$/    permissions: {}/; /^      contents: read$/d; /^      actions: read/d'
check "and the same job with permissions: {} of its own is accepted" "" "$(violations "$BAD")"
fixture commit-hygiene.yml 's/^    permissions:$/    permissions: write-all/; /^      contents: read$/d'
check "a job that grants write-all is named for the job, twice as there are two" \
	"commit-hygiene.yml: commit-identity grants write-all; name each permission, \`{}\` when it needs none
commit-hygiene.yml: secret-scan grants write-all; name each permission, \`{}\` when it needs none" "$(violations "$BAD")"

# The one job that holds a write: the scope it needs is accepted, and every
# other scope, in that job and in any other, is named.
fixture cancel-others.yml 's/^      actions: write      # only in this job$/      actions: write\n      contents: write/'
check "a write the cancel job does not need is named for the job" \
	"cancel-others.yml: cancel-others holds contents: write; nothing in this repository writes to GitHub" "$(violations "$BAD")"
rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
printf 'on: push\npermissions:\n  contents: read\njobs:\n  other:\n    permissions:\n      contents: read\n      actions: write\n    runs-on: ubuntu-26.04\n    steps:\n      - run: true\n' > "$BAD/extra.yaml"
check "a write in a job that is not the cancel job is named for the job" \
	"extra.yaml: other holds actions: write; nothing in this repository writes to GitHub" "$(violations "$BAD")"
fixture cancel-others.yml 's/^      actions: write      # only in this job$//'
check "the cancel job without its write is accepted" "" "$(violations "$BAD")"

# A workflow named .yaml is a workflow too, and a directory with none is not a pass.
rm -f "$BAD"/*; cp "$HERE"/.github/workflows/*.y*ml "$BAD/"
printf 'on: push\njobs:\n  sneak:\n    runs-on: ubuntu-26.04\n    steps:\n      - run: true\n' > "$BAD/extra.yaml"
check "a .yaml workflow with no permissions is named" \
	"extra.yaml: declares no permissions for the workflow, so every job gets the default of the repository" "$(violations "$BAD")"
printf 'on: push\npermissions: {}\njobs:\n  sneak:\n    runs-on: ubuntu-26.04\n    steps:\n      - run: echo "$X"\n        env:\n          X: ${{ secrets.TOKEN }}\n' > "$BAD/extra.yaml"
check "and a job with a secret in a step and no permissions of its own is named, whatever the workflow says" \
	"extra.yaml: sneak names a secret and declares no permissions of its own" "$(violations "$BAD")"
printf 'on: push\npermissions: {}\njobs:\n  call:\n    uses: ./.github/workflows/reusable-dco.yml\n    secrets: inherit\n' > "$BAD/extra.yaml"
check "and a caller that passes its secrets on is named too" \
	"extra.yaml: call names a secret and declares no permissions of its own" "$(violations "$BAD")"
printf 'on: [push\n' > "$BAD/extra.yaml"
check "a file that is not YAML is named, not skipped" \
	"extra.yaml: cannot be read as a workflow, so its permissions are unknown" "$(violations "$BAD")"
rm -f "$BAD"/*
check "a directory with no workflow is not a pass" "no workflow was found, so nothing was inspected" "$(violations "$BAD")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
