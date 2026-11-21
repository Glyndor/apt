#!/usr/bin/env bash
# Fail when a tool version pinned inside the workflows has been left behind its
# upstream release for longer than the allowed lag.
#
# WHY THIS EXISTS
#
# Both shellcheck and actionlint decide a required check, and each is pinned by
# version and sha256 inside a reusable workflow. Dependabot's github-actions
# ecosystem moves `uses:` pins and nothing else, and dependabot-freshness reads
# only those pins, so a version written as a value inside a workflow had no
# update path: it moved when somebody remembered. A frozen linter stays green
# while the releases after it fix bugs and learn new checks, and nothing says
# so. This script is the thing that says so.
#
# WHAT IT READS
#
#   - For shellcheck, the `shellcheck-version` input default of
#     reusable-shell-ci.yml and of reusable-workflow-lint.yml. The two install
#     the same linter for two checks, so they must name the same version; two
#     different ones fail here before upstream is asked anything.
#   - For actionlint, ACTIONLINT_VERSION in the env of reusable-workflow-lint.yml.
#
# Upstream is the newest releases of koalaman/shellcheck and rhysd/actionlint,
# read with `gh release list` and the job's own token. Drafts and pre-releases
# do not count, nor does a tag that is not vMAJOR.MINOR.PATCH.
#
# HOW BEHIND IS MEASURED
#
# From the publication of the FIRST release newer than the pin, not of the
# newest one. A tool that releases every few weeks would otherwise reset the
# clock with every release, and a pin three releases behind would read as
# fresh for ever.
#
# THE LAG
#
# MAX_LAG_DAYS, 30 by default. A new linter release is not free to adopt: it
# can report findings the old one did not, the version and its sha256 move
# together in the reusables of three channel repositories, and the reusable
# drift check holds those copies to each other, so the bump is three pull
# requests landed together. Two weeks is too short to plan that around other
# work; after a month, being behind is a decision somebody did not write down,
# not latency.
#
# OUTCOMES
#
#   current          the pin is the newest release
#   behind, in lag   a newer release exists, published within the lag; a notice
#   behind, past it  a newer release has been out longer than the lag; failure
#   unreadable       a pin that cannot be read, two shellcheck pins that differ,
#                    an upstream that cannot be read or lists no release, or a
#                    pin newer than every upstream release; failure, never a
#                    skip, because a watcher that drops what it cannot read
#                    reports success over a smaller set than it claims
#
# Usage: check-tool-versions.sh [repo-root]   (default: the repo this lives in)
# Environment: MAX_LAG_DAYS; CHECK_TOOL_VERSIONS_NOW (epoch seconds, for tests).
set -euo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
python3 -I - "$root" <<'PY'
import datetime
import json
import os
import re
import subprocess
import sys

import yaml

ROOT = sys.argv[1]
SEMVER = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)")
problems = []


def workflow(name):
    with open(os.path.join(ROOT, ".github/workflows", name)) as fh:
        return yaml.safe_load(fh)


def input_default(spec, name):
    # PyYAML reads the bare key `on` as the boolean True.
    on = spec.get(True, spec.get("on")) or {}
    inputs = (on.get("workflow_call") or {}).get("inputs") or {}
    return (inputs.get(name) or {}).get("default")


def version(text):
    match = SEMVER.fullmatch(str(text))
    return tuple(int(part) for part in match.groups()) if match else None


def pins():
    """The pinned tools as (tool, upstream, version), or None after a problem."""
    try:
        shell_ci = workflow("reusable-shell-ci.yml")
        lint = workflow("reusable-workflow-lint.yml")
    except (OSError, yaml.YAMLError) as exc:
        problems.append(f"cannot read the reusables that pin the tools: {exc}")
        return None
    found = []
    shellcheck = {input_default(shell_ci, "shellcheck-version"),
                  input_default(lint, "shellcheck-version")}
    if len(shellcheck) != 1:
        problems.append("reusable-shell-ci.yml and reusable-workflow-lint.yml pin "
                        f"different shellcheck versions: {sorted(map(str, shellcheck))}")
    else:
        found.append(("shellcheck", "koalaman/shellcheck", shellcheck.pop()))
    env = ((lint.get("jobs") or {}).get("workflow-lint") or {}).get("env") or {}
    found.append(("actionlint", "rhysd/actionlint", env.get("ACTIONLINT_VERSION")))
    for tool, _, pinned in found:
        if version(pinned) is None:
            problems.append(f"{tool}: the pinned version {pinned!r} is not vMAJOR.MINOR.PATCH")
    return [entry for entry in found if version(entry[2]) is not None]


def releases(upstream):
    """Published, non-prerelease vX.Y.Z releases as {version: datetime}, or None."""
    cmd = ["gh", "release", "list", "--repo", upstream, "--exclude-drafts",
           "--exclude-pre-releases", "--limit", "100", "--json", "tagName,publishedAt"]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120).stdout
        listed = json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        problems.append(f"cannot read the releases of {upstream}: {exc}")
        return None
    found = {}
    if isinstance(listed, list):
        for entry in listed:
            if not isinstance(entry, dict):
                continue
            parsed = version(entry.get("tagName", ""))
            try:
                published = datetime.datetime.fromisoformat(
                    str(entry.get("publishedAt", "")).replace("Z", "+00:00"))
            except ValueError:
                continue
            if parsed is not None and published.tzinfo is not None:
                found[parsed] = published
    if not found:
        problems.append(f"{upstream} lists no vMAJOR.MINOR.PATCH release, so nothing was compared")
        return None
    return found


lag_days = int(os.environ.get("MAX_LAG_DAYS", "30"))
now_epoch = os.environ.get("CHECK_TOOL_VERSIONS_NOW")
now = (datetime.datetime.fromtimestamp(int(now_epoch), datetime.timezone.utc)
       if now_epoch else datetime.datetime.now(datetime.timezone.utc))
behind = []
compared = 0
for tool, upstream, pinned in pins() or []:
    published = releases(upstream)
    if published is None:
        continue
    pin = version(pinned)
    newest = max(published)
    if pin > newest:
        problems.append(f"{tool}: the pinned {pinned} is newer than every release of {upstream}")
        continue
    compared += 1
    newer = [published[v] for v in published if v > pin]
    latest = "v%d.%d.%d" % newest
    if not newer:
        print(f"{tool}: {pinned} is the newest release of {upstream}.")
        continue
    days = (now - min(newer)).days
    if days > lag_days:
        behind.append(f"{tool}: {pinned} is pinned, {latest} is the newest release of {upstream}, "
                      f"and the first release after the pin has been out {days} days "
                      f"(the allowed lag is {lag_days}). Move the version and its sha256 "
                      "in the reusables of the three channels together.")
    else:
        print(f"::notice::{tool}: {pinned} is pinned and {latest} is out; the first release "
              f"after the pin is {days} days old, within the {lag_days}-day lag.")
for message in problems:
    print(f"::error::{message}")
for message in behind:
    print(f"::error::{message}")
if problems or behind:
    sys.exit(1)
print(f"tool versions: {compared} pinned tool(s) compared with upstream, none behind past {lag_days} days.")
PY
