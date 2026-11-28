#!/usr/bin/env bash
#
# Some workflows call the same script more than once, each time asking a different question, and
# the script's name alone does not say which question is still being asked. freshness.yml runs
# check-suite-on-main.sh twice, for line-limit.yml and workflow-lint.yml; each call is the only
# reader of the runs it names, and deleting either left every suite green because the other call
# still held the script's name. commit-hygiene.yml is read by no
# other suite at all: its two steps are the only place the commit identity and the credential
# scan run on a pull request.
#
# workflows-run-their-scripts.test.sh pins that a script is run. This pins the whole command
# line of the calls it cannot tell apart, as a line that runs it and not a comment or an echo
# that names it. Each pinned call is then broken in a copy, four ways, and each must be reported
# by name: replaced by `:`, with its last argument changed, commented out, and echoed.
#
# Requires: python3 (standard library only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
SUITE_ON_MAIN = "./scripts/monitoring/check-suite-on-main.sh"
PINNED = {
    "freshness.yml": [
        f'{SUITE_ON_MAIN} "$REPO" line-limit.yml main',
        f'{SUITE_ON_MAIN} "$REPO" workflow-lint.yml main',
    ],
    # Each step reads its script from the base commit into a file of its own and runs that,
    # so the pull request's copy of the script is never the one that judges it. The file is
    # run with `bash`, which does not depend on its mode.
    "commit-hygiene.yml": [
        'git show "$BASE:scripts/quality/hygiene/check-commit-identity.sh" > "$identity"',
        'bash "$identity" "$BASE" "$HEAD"',
        'git show "$BASE:scripts/quality/hygiene/check-secrets.sh" > "$scan"',
        'bash "$scan" "$BASE" "$HEAD"',
    ],
}
passed = failed = 0


def check(name, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}: expected {expected!r}, got {actual!r}")


def body(raw):
    """What a line asks the shell to run: the text after `run:`, `- ` or the block-scalar bar."""
    line = re.sub(r"^-\s+", "", raw.strip())
    return re.sub(r"^run:\s*(?:\|[-+]?\s*)?", "", line)


def missing(text, calls):
    """The pinned calls no line runs, each named by its whole command."""
    lines = [body(raw) for raw in text.splitlines() if not raw.strip().startswith("#")]
    return [f"not run: {call}" for call in calls if call not in lines]


def replaced(text, call, new):
    """Every line that runs `call` with its command swapped for `new`."""
    out = []
    for raw in text.splitlines():
        if not raw.strip().startswith("#") and body(raw) == call:
            raw = raw.replace(call, new)
        out.append(raw)
    return "\n".join(out) + "\n"


for workflow, calls in PINNED.items():
    text = (root / ".github/workflows" / workflow).read_text()
    check(f"{workflow} runs every pinned call", [], missing(text, calls))
    for call in calls:
        # The same workflow without that one call: the report names it and no other.
        broken = {
            "replaced by :": replaced(text, call, ":"),
            "with its last argument changed": replaced(text, call, call.rsplit(" ", 1)[0] + " other"),
            "commented out": replaced(text, call, "# " + call),
            "echoed instead of run": replaced(text, call, f"echo {call}"),
        }
        for how, mutated in broken.items():
            check(f"  {workflow}: {call.split('/')[-1]} {how} is reported",
                  [f"not run: {call}"], missing(mutated, calls))
        # A copy that kept the call must still be accepted, so a pin that refuses everything fails.
        check(f"  {workflow}: the call left alone is accepted", [], missing(replaced(text, call, call), calls))

print(f"{passed} passed, {failed} failed")
print(f"DONE {Path(sys.argv[0]).name if sys.argv[0] != '-' else 'workflow-calls-are-exact.test.sh'} {passed} {failed}")
sys.exit(1 if failed else 0)
PY
