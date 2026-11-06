#!/usr/bin/env bash
# Removing a route classifier, the old-blob inspection or a fail-open branch
# must change a decision below. All diffs and blobs come from real git commits.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$HERE" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]) / "scripts/quality/ci-job-scope.sh"
passed = failed = 0
jobs = ("shellcheck", "workflow-lint", "line-limit")


def check(name, want, got):
    global passed, failed
    if want == got:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}: expected {want!r}, got {got!r}")


with tempfile.TemporaryDirectory() as tmp:
    repo = Path(tmp)

    def git(*args):
        return subprocess.run(["git", *args], cwd=repo, check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    def write(path, body):
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)

    git("init", "-q", "-b", "main")
    git("config", "user.name", "t")
    git("config", "user.email", "t@example.invalid")
    git("config", "commit.gpgsign", "false")
    write("README.md", "readme\n")
    write("hook", "#!/bin/sh\necho before\n")
    write(".github/workflows/run.yml", "jobs:\n  t:\n    steps:\n      - run: echo before\n")
    git("add", "-A")
    git("commit", "-qm", "I seed the fixture", "-s")
    base = git("rev-parse", "HEAD").decode().strip()

    def merge(changes):
        git("checkout", "-q", "-B", "main", base)
        git("checkout", "-q", "-B", "pr")
        for path, body in changes.items():
            if body is None:
                (repo / path).unlink()
            else:
                write(path, body)
        git("add", "-A")
        git("commit", "-qm", "I change the fixture", "--allow-empty", "-s")
        git("checkout", "-q", "main")
        git("merge", "-q", "--no-ff", "pr", "-m", "I merge the fixture", "--signoff")

    def decide(job, event="pull_request", extensions="sh py yml yaml", extra=None):
        env = dict(os.environ, EVENT=event, EXTS=extensions)
        env.update(extra or {})
        p = subprocess.run(["bash", str(script), job], cwd=repo, env=env,
                           text=True, capture_output=True)
        return p.stdout.strip() if p.returncode == 0 else f"exit {p.returncode}: {p.stderr.strip()}"

    # Expected vectors are literal and independent of the implementation.
    cases = [
        ("readme", {"README.md": "new prose\n"}, (False, False, False)),
        ("docs", {"docs/guide.md": "guide\n"}, (False, False, False)),
        ("contributing", {"CONTRIBUTING.md": "guide\n"}, (False, False, False)),
        ("license", {"LICENSE": "license\n"}, (False, False, False)),
        ("owners", {".github/CODEOWNERS": "* @owner\n"}, (False, False, False)),
        ("issue", {".github/ISSUE_TEMPLATE/x.yml": "name: bug\n"}, (False, False, True)),
        ("dependabot", {".github/dependabot.yml": "version: 2\n"}, (False, False, True)),
        ("editorconfig", {".editorconfig": "root = true\n"}, (False, False, False)),
        ("key", {"keyring/key.asc": "key\n"}, (False, False, False)),
        ("shell extension", {"scripts/new.sh": "echo hi\n"}, (True, False, True)),
        ("bash extension", {"scripts/new.bash": "echo hi\n"}, (True, False, False)),
        ("shell shebang", {"bin/tool": "#!/usr/bin/env bash\necho hi\n"}, (True, False, False)),
        ("dash shebang", {"bin/tool": "#!/bin/dash\necho hi\n"}, (True, False, False)),
        ("python shebang", {"bin/tool": "#!/usr/bin/python3\npass\n"}, (False, False, False)),
        ("counted extension", {"tool.py": "pass\n"}, (False, False, True)),
        ("workflow run", {".github/workflows/new.yml": "jobs: {t: {steps: [{run: 'echo hi'}]}}\n"}, (True, True, True)),
        ("workflow without run", {".github/workflows/call.yml": "jobs: {t: {uses: './other.yml'}}\n"}, (False, True, True)),
        ("workflow removed run", {".github/workflows/run.yml": "jobs: {}\n"}, (True, True, True)),
        ("workflow deleted", {".github/workflows/run.yml": None}, (True, True, True)),
        ("shell config", {".shellcheckrc": "severity=warning\n"}, (True, True, False)),
        ("nested shell config", {"scripts/.shellcheckrc": "severity=warning\n"}, (True, True, False)),
        ("actionlint config", {".github/actionlint.yaml": "self-hosted-runner: {}\n"}, (False, True, True)),
        ("actionlint config yml", {".github/actionlint.yml": "self-hosted-runner: {}\n"}, (False, True, True)),
        ("shell caller config", {".github/workflows/tests.yml": "jobs: {}\n"}, (True, True, True)),
        ("shell reusable config", {".github/workflows/reusable-shell-ci.yml": "jobs: {}\n"}, (True, True, True)),
        ("line caller config", {".github/workflows/line-limit.yml": "jobs: {}\n"}, (False, True, True)),
        ("line reusable config", {".github/workflows/reusable-line-limit.yml": "jobs: {}\n"}, (False, True, True)),
        ("scope itself", {"scripts/quality/ci-job-scope.sh": "# changed\n"}, (True, True, True)),
        ("shebang removed", {"hook": "plain text\n"}, (True, False, False)),
        ("shebang deleted", {"hook": None}, (True, False, False)),
        ("rename", {"hook": None, "docs/hook.md": "#!/bin/sh\necho before\n"}, (True, True, True)),
        ("prose rename", {"README.md": None, "notes.md": "readme\n"}, (True, True, True)),
        ("quoted path", {"docs/a\nb.md": "guide\n"}, (False, False, False)),
        ("mixed", {"README.md": "more\n", "new.sh": "echo hi\n"}, (True, False, True)),
        ("empty", {}, (True, True, True)),
    ]
    for name, changes, wants in cases:
        merge(changes)
        for job, want in zip(jobs, wants):
            check(f"{name}: {job}", str(want).lower(), decide(job))

    merge({"README.md": "another\n"})
    for event in ("push", "schedule", "workflow_dispatch", "merge_group"):
        for job in jobs:
            check(f"{event}: {job}", "true", decide(job, event))
    merge({"tool.rs": "fn main() {}\n"})
    check("line-limit uses caller extensions", "true", decide("line-limit", extensions="rs"))
    check("line-limit excludes uncounted extension", "false", decide("line-limit", extensions="sh"))
    merge({".github/workflows/line-limit.yml": "jobs: {}\n"})
    check("line-limit config even without YAML extension", "true", decide("line-limit", extensions="sh"))
    # A module planted by the pull request must not decide its own lint: the
    # interpreter runs isolated, so the working directory is not on sys.path.
    merge({"re.py": "print('false')\nraise SystemExit(0)\n", "planted.sh": "echo hi\n"})
    check("planted module cannot skip shellcheck", "true", decide("shellcheck"))
    git("checkout", "-q", "--detach", base)
    for job in jobs:
        check(f"unreadable parent: {job}", "true", decide(job))

print(f"{passed} passed, {failed} failed")
print(f"DONE ci-job-scope.test.sh {passed} {failed}")
sys.exit(bool(failed))
PY
