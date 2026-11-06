#!/usr/bin/env bash
# build-repo.test.sh covers runtime key membership. This structural test
# keeps its duplicate in the workflow's independent bootstrap-signing step.
# It checks executable lines in that step, so comments or another step cannot
# stand in for the guard. No deployment credentials or third-party YAML needed.
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 - <<'PY'
from pathlib import Path
import re

workflow = Path('.github/workflows/publish.yml').read_text()
steps = dict(re.findall(
    r'^      - name: ([^\n]+)\n(.*?)(?=^      - (?:name:|uses:)|\Z)',
    workflow, re.M | re.S,
))
signing = steps.get('Sign the keyring package', '')
commands = '\n'.join(
    line.strip() for line in signing.splitlines()
    if line.strip() and not line.lstrip().startswith('#')
)
guard = '''if ! gpg --batch --with-colons --show-keys keyring/glyndor-apt-key.asc \\
| awk -F: '/^fpr:/{print $10}' | grep -qxF "$FPR"; then
echo "::error::signing key ($FPR) is not present in keyring/glyndor-apt-key.asc"
exit 1
fi'''
checks = [
    ('the signing step retains its public-key membership refusal', guard in commands),
    ('membership is checked before the served package is signed',
     guard in commands and commands.index(guard) < commands.find(
         'gpg --batch --local-user "$FPR" --armor --detach-sign')),
]
failed = 0
for description, accepted in checks:
    print(('ok    ' if accepted else 'FAIL  ') + description)
    failed += not accepted
passed = len(checks) - failed
print(f'{passed} passed, {failed} failed')
print(f'DONE publish-workflow-signing-key.test.sh {passed} {failed}')
raise SystemExit(bool(failed))
PY
