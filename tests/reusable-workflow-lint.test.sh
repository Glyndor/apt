#!/usr/bin/env bash
# Behaviour tests for the two assertions this repository adds to
# .github/workflows/reusable-workflow-lint.yml on top of actionlint.
#
# Both are gates over other gates. One parses every caller of
# reusable-shell-ci and refuses, each with its own message, the mechanisms
# that can switch the required `shell / test` check off without failing it:
# a job-level `if:`, an empty or malformed test-command, and the suppression
# forms (`|| true`, `true ||`, `exit 0`). The other refuses a job that
# installs third-party tooling while holding a secret. Neither had a test: a
# script that gates gets tests, and its schedule is when it reports, not
# when it is verified.
#
# Each step's `run:` body is extracted from the workflow and executed as it
# ships, in a temporary tree shaped like a repository. Every refusal asserts
# which refusal, and every refusal is paired with an acceptance of the same
# shape just inside the line.
#
# Requires: python3 with PyYAML (the tooling-isolation step imports it, and
# the caller-assertion step parses YAML itself).
# The fixtures below carry literal `${{ secrets.X }}` expressions and backticks:
# the assertion under test reads those characters, so they must reach the file
# unexpanded. Single quotes are the point, not an oversight.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Pull one step's `run:` body out of a workflow, dedented, so it can be run.
# Same helper as tests/update-workflow.test.sh: the point is to exercise the
# shell as it ships rather than a copy of it that can drift.
step_script() { # $1=workflow path  $2=step name substring
	python3 - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if not line.strip():
        body.append("")
        continue
    if not line.startswith(" " * 10):
        break
    body.append(line[10:])
print("\n".join(body))
PY
}

WORKFLOW="$HERE/.github/workflows/reusable-workflow-lint.yml"
step_script "$WORKFLOW" "A required test job must not be switchable off" > "$WORK/callers.sh"
step_script "$WORKFLOW" "A job holding a secret must not install" > "$WORK/tooling.sh"
check "the caller assertion was extracted from the workflow" "1" \
	"$(grep -c 'reusable-shell-ci' "$WORK/callers.sh" | awk '{print ($1>0)}')"
check "the tooling assertion was extracted from the workflow" "1" \
	"$(grep -c 'INSTALL_PATTERNS' "$WORK/tooling.sh" | awk '{print ($1>0)}')"

new() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/.github/workflows"; printf '%s' "$WORK/t"; }
run_in() { # $1=dir $2=script -> stdout+stderr, status in $?
	( cd "$1" && bash "$2" 2>&1 )
}
said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

# A caller of reusable-shell-ci, with whatever test-command the case wants.
# The value is folded onto following lines by `>-`, so a YAML block scalar
# here is what every real caller uses too; the parser reads it back into a
# single string before checking it.
caller() { # $1=dir $2=test-command value (may be empty)
	cat > "$1/.github/workflows/tests.yml" <<EOF
name: Tests
on: pull_request
jobs:
  shell:
    uses: ./.github/workflows/reusable-shell-ci.yml
    with:
      test-command: >-
        $2
      apt-packages: shellcheck
EOF
}

# ===========================================================================
# A required test job must not be switchable off
# ===========================================================================

# Like caller(), but adds a job-level `if:` value. The previous text match
# could not see this key at all; the parser must, and must refuse any value
# because any conditional on a caller of a required job is a switch.
caller_if() { # $1=dir $2=test-command value $3=if value
	cat > "$1/.github/workflows/tests.yml" <<EOF
name: Tests
on: pull_request
jobs:
  shell:
    if: $3
    uses: ./.github/workflows/reusable-shell-ci.yml
    with:
      test-command: >-
        $2
      apt-packages: shellcheck
EOF
}

# --- the repository's real caller is the positive control ------------------
d="$(new)"
cp "$HERE/.github/workflows/tests.yml" "$d/.github/workflows/"
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "the real tests.yml caller stays accepted" "0" "$rc"
check "and the step says every caller passes" "1" \
	"$(said "$out" 'every reusable-shell-ci caller passes')"

# --- a caller that runs a suite passes (sanity check) ---------------------
d="$(new)"; caller "$d" './tests/one.test.sh && ./tests/two.test.sh'
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a caller whose test-command runs a suite passes" "0" "$rc"

# --- a job-level `if:` on a caller is refused, for that reason -------------
d="$(new)"; caller_if "$d" './tests/one.test.sh' 'false'
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a caller with a job-level if: is refused" "1" "$rc"
check "and the message names the if: defect, not something else" "1" \
	"$(said "$out" 'job-level `if:`')"
check "and the offending job is named" "1" "$(said "$out" '`shell`')"
check "and no grammar message fires alongside" "0" \
	"$(said "$out" 'first non-blank token')"

# --- a test-command whose first token is not a suite is refused ------------
d="$(new)"; caller "$d" 'echo tests are elsewhere'
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a test-command that runs no ./tests/*.test.sh is refused" "1" "$rc"
check "and the message names the first-token defect" "1" \
	"$(said "$out" 'first non-blank token is not a suite invocation')"
check "and the offending workflow is named" "1" "$(said "$out" 'tests.yml')"
check "and no if: message fires alongside" "0" \
	"$(said "$out" 'job-level `if:`')"

# --- an empty test-command is refused (existing rule, kept) ---------------
d="$(new)"; caller "$d" ''
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a caller with an empty test-command is refused" "1" "$rc"
check "and it is refused for the test-command, not something else" "1" \
	"$(said "$out" 'without a test-command that runs any suite')"
check "and the offending workflow is named" "1" "$(said "$out" 'tests.yml')"

# --- a `|| true` anywhere in the test-command is refused -------------------
d="$(new)"; caller "$d" './tests/one.test.sh || true'
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a test-command with || true is refused" "1" "$rc"
check "and the message names the infix suppression form" "1" \
	"$(said "$out" '`|| true`')"
check "and it is not refused as the prefix form" "0" \
	"$(said "$out" 'starts with `true ||`')"
check "and it is not refused as the exit-0 form" "0" \
	"$(said "$out" '`exit 0`')"

# --- a `true ||` prefix on the test-command is refused --------------------
d="$(new)"; caller "$d" 'true || ./tests/one.test.sh && ./tests/two.test.sh'
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a test-command with true || prefix is refused" "1" "$rc"
check "and the message names the prefix form" "1" \
	"$(said "$out" 'starts with `true ||`')"
check "and it is not refused as the infix form" "0" \
	"$(said "$out" '`|| true`')"
check "and it is not refused as the exit-0 form" "0" \
	"$(said "$out" '`exit 0`')"

# --- a leading `exit 0` on the test-command is refused --------------------
d="$(new)"; caller "$d" 'exit 0'
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a test-command starting with exit 0 is refused" "1" "$rc"
check "and the message names the exit-0 form" "1" \
	"$(said "$out" '`exit 0`')"
check "and it is not refused as the prefix form" "0" \
	"$(said "$out" 'starts with `true ||`')"
check "and it is not refused as the infix form" "0" \
	"$(said "$out" '`|| true`')"

# --- no caller at all is refused, and named as the other failure ----------
d="$(new)"
cat > "$d/.github/workflows/other.yml" <<'EOF'
name: Other
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: true
EOF
out="$(run_in "$d" "$WORK/callers.sh")"; rc=$?
check "a tree with no reusable-shell-ci caller is refused" "1" "$rc"
check "and it says no workflow calls it, which is the other failure" "1" \
	"$(said "$out" 'no workflow calls reusable-shell-ci')"

# --- the reusable itself is not counted as a caller -----------------------
d="$(new)"
cp "$HERE/.github/workflows/reusable-shell-ci.yml" "$d/.github/workflows/"
rc=0; run_in "$d" "$WORK/callers.sh" >/dev/null || rc=$?
check "the reusable's own file does not count as a caller" "1" "$rc"

# ===========================================================================
# A job holding a secret must not install third-party tooling
# ===========================================================================

tooling_case() { # $1=dir $2=env line (or empty) $3=run line
	cat > "$1/.github/workflows/job.yml" <<EOF
name: Job
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      $2
    steps:
      - run: |
          $3
EOF
}

# --- a secret plus a pip install is refused, and named --------------------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'pip install requests'
out="$(run_in "$d" "$WORK/tooling.sh")"; rc=$?
check "a job holding a secret that pip installs is refused" "1" "$rc"
check "and the message names the job and the line" "1" \
	"$(said "$out" 'job `build` installs third-party tooling while holding a secret: `pip install requests`')"

# --- the same install pinned by hash is the documented exemption ----------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'pip install --require-hashes -r req.txt'
out="$(run_in "$d" "$WORK/tooling.sh")"; rc=$?
check "pip install --require-hashes while holding a secret is allowed" "0" "$rc"
check "and the step says nothing was found" "1" "$(said "$out" 'no job holding a secret installs')"

# --- cargo install has no hash exemption ---------------------------------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'cargo install --locked cargo-cyclonedx'
rc=0; run_in "$d" "$WORK/tooling.sh" >/dev/null || rc=$?
check "cargo install --locked while holding a secret is still refused" "1" "$rc"

# --- the same install without a secret is fine ---------------------------
d="$(new)"; tooling_case "$d" 'PLAIN: value' 'cargo install --locked cargo-cyclonedx'
rc=0; run_in "$d" "$WORK/tooling.sh" >/dev/null || rc=$?
check "the same install in a job holding no secret passes" "0" "$rc"

# --- a commented-out install is not an install ---------------------------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' '# pip install requests'
rc=0; run_in "$d" "$WORK/tooling.sh" >/dev/null || rc=$?
check "an install that only appears in a comment is not reported" "0" "$rc"

# --- a secret referenced in a step, not the job env, still counts --------
d="$(new)"
cat > "$d/.github/workflows/job.yml" <<'EOF'
name: Job
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: go install example.com/tool@v1
      - run: echo "$KEY"
        env:
          KEY: ${{ secrets.SIGNING_KEY }}
EOF
rc=0; run_in "$d" "$WORK/tooling.sh" >/dev/null || rc=$?
check "a secret held by a later step of the same job still counts" "1" "$rc"

# --- a `secrets:` declaration is not a reference -------------------------
d="$(new)"
cat > "$d/.github/workflows/job.yml" <<'EOF'
name: Job
on: push
jobs:
  call:
    uses: ./.github/workflows/reusable-x.yml
    secrets: inherit
  build:
    runs-on: ubuntu-latest
    steps:
      - run: go install example.com/tool@v1
EOF
rc=0; run_in "$d" "$WORK/tooling.sh" >/dev/null || rc=$?
check "secrets: inherit on a reusable call is not a secret reference" "0" "$rc"

# --- an unparseable workflow is a warning, not a silent skip -------------
d="$(new)"; printf 'name: [\n' > "$d/.github/workflows/broken.yml"
out="$(run_in "$d" "$WORK/tooling.sh")"; rc=$?
check "a workflow that does not parse does not fail the step" "0" "$rc"
check "but is reported as skipped, so the silence is visible" "1" "$(said "$out" '::warning')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
