#!/usr/bin/env bash
# The archive key signs two things in a publish: the index, through reprepro's
# SignWith, and the bootstrap keyring package, with a detached signature. Both
# are made by scripts/build/build-repo.sh from one import of the secret, and
# both have to come after the two checks on that key: exactly one secret key,
# and that key present in keyring/glyndor-apt-key.asc.
#
# tests/build/build-repo.test.sh and publish-workflow-bootstrap.test.sh run the
# refusals. This pins their ORDER against both signatures, on executable lines
# only, so a signature moved above the checks, or a comment that merely names
# them, cannot pass. No deployment credentials or third-party YAML needed.
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 -I - <<'PY'
from pathlib import Path

lines = [
    line.strip() for line in Path("scripts/build/build-repo.sh").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]


def first(fragment):
    return next((i for i, line in enumerate(lines) if fragment in line), None)


count = first('[ "$SEC_COUNT" -eq 1 ] || {')
membership = first("| awk -F: '/^fpr:/{print $10}' | grep -qxF \"$FPR\"; then")
index_sig = first("SignWith: $FPR")
bootstrap_sig = first('gpg --batch --local-user "$FPR" --armor --detach-sign \\')


def before(a, b):
    return a is not None and b is not None and a < b


checks = [
    ("build-repo.sh refuses a secret that is not exactly one key", count is not None),
    ("build-repo.sh refuses a key absent from the committed keyring", membership is not None),
    ("the one-key check comes before the index is signed", before(count, index_sig)),
    ("the membership check comes before the index is signed", before(membership, index_sig)),
    ("the one-key check comes before the bootstrap package is signed", before(count, bootstrap_sig)),
    ("the membership check comes before the bootstrap package is signed",
     before(membership, bootstrap_sig)),
]
failed = 0
for description, accepted in checks:
    print(("ok    " if accepted else "FAIL  ") + description)
    failed += not accepted
passed = len(checks) - failed
print(f"{passed} passed, {failed} failed")
print(f"DONE publish-workflow-signing-key.test.sh {passed} {failed}")
raise SystemExit(bool(failed))
PY
