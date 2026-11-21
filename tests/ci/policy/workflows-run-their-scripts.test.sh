#!/usr/bin/env bash
#
# A workflow step that stops calling its script leaves every suite of that script green and the
# gate it stood for gone: the script's own test never reads the workflow. A mutation audit
# replaced two such calls with `:` and nothing failed. This pins, per workflow, the scripts it
# must run, as a line that runs the script and not a comment or an echo that names it. Each
# pinned call is then replaced by `:` in a copy and must be reported, which shows the check
# looks at the call and not only at the file.
#
# Requires: python3 (standard library only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
PINNED = {
    "drift.yml": ["scripts/monitoring/check-reusable-drift.sh"],
    "freshness.yml": ["scripts/monitoring/check-suite-on-main.sh", "scripts/monitoring/check-tool-versions.sh"],
    "health-check.yml": [
        "scripts/verify/verify-published.sh",
        "scripts/verify/reference-installers.sh",
        "scripts/verify/verify-installers.sh",
    ],
    "mutation.yml": ["tests/mutation/run-mutations.sh"],
    "roster-releases.yml": ["scripts/verify/roster-has-releases.sh"],
    "publish.yml": [
        "scripts/verify/check-release-order.sh",
        "scripts/verify/verify-debs.sh",
        "scripts/build/build-keyring.sh",
        "scripts/build/build-repo.sh",
        "scripts/build/build-installers.sh",
        "scripts/publish/sync-archive.sh",
        "scripts/publish/prune-installers.sh",
        "scripts/publish/purge-cache.sh",
        "scripts/verify/verify-installers.sh",
        "scripts/verify/verify-published.sh",
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


def runs(text, script):
    """A line that starts the script as a command, not a comment or an argument of another."""
    pattern = re.compile(r"^(?:run:\s*)?(?:\|\s*)?(?:bash\s+)?\./" + re.escape(script) + r"(?:\s|$)")
    return any(pattern.match(line.strip()) for line in text.splitlines()
               if not line.strip().startswith("#"))


for workflow, scripts in PINNED.items():
    text = (root / ".github/workflows" / workflow).read_text()
    for script in scripts:
        check(f"{workflow} runs {script}", True, runs(text, script))
        # Replace that call, in every place it is made, by `:` and it must be reported.
        mutated = re.sub(r"(?m)^(\s*(?:run:\s*)?(?:bash\s+)?)\./" + re.escape(script), r"\1:", text)
        check(f"  and is reported when {script} is replaced by :", False, runs(mutated, script))

print(f"{passed} passed, {failed} failed")
print(f"DONE {Path(sys.argv[0]).name if sys.argv[0] != '-' else 'workflows-run-their-scripts.test.sh'} {passed} {failed}")
sys.exit(1 if failed else 0)
PY
