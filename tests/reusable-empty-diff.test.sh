#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-empty-diff.yml.
#
# The gate exists so a pull request that changes nothing cannot merge and look
# like it did something. It reads the base ref from the environment, which is
# all it takes from GitHub, so a local repository with an origin exercises the
# same code.
#
# Requires: python3, git.
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

WORKFLOW="$HERE/.github/workflows/reusable-empty-diff.yml"
step_script "$WORKFLOW" "Fail when the pull request changes nothing" > "$WORK/step.sh"

# A clone, so `origin/<base>` resolves the way it does on a runner.
# -b main on both, rather than relying on init.defaultBranch. Without it the
# bare repository's HEAD points at whatever the runner's git defaults to,
# which need not be the branch that gets pushed, and `git clone` then prints
# "remote HEAD refers to nonexistent ref, unable to checkout" and leaves an
# empty working tree. The tests still ran and two of them passed for the
# wrong reason. That is the shape of a test measuring the machine's
# configuration instead of the code, and it passed locally for exactly that
# reason: this machine sets init.defaultBranch to main and the runner does not.
upstream="$WORK/up"
git init -q --bare -b main "$upstream"
seed="$WORK/seed"
git init -q -b main "$seed"
git -C "$seed" config user.email t@example.invalid
git -C "$seed" config user.name t
echo one > "$seed/f"
git -C "$seed" add -A && git -C "$seed" commit -qm seed
git -C "$seed" remote add origin "$upstream"
git -C "$seed" push -q origin main

repo="$WORK/r"
git clone -q "$upstream" "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t

# The clone must have checked something out. Without this, a clone that
# silently produced an empty tree would let the cases below pass or fail for
# reasons that have nothing to do with the gate under test.
check "the fixture clone checked out the base branch" "main" \
	"$(git -C "$repo" rev-parse --abbrev-ref HEAD)"

run_step() { # $1=BASE value
	( cd "$repo" && BASE="$1" bash "$WORK/step.sh" 2>&1 )
}

# --- no base ref at all --------------------------------------------------

out="$(run_step "")"; rc=$?
check "an empty base ref fails rather than passing by default" "1" "$rc"
check "and says the reusable needs a pull_request trigger" "1" \
	"$(printf '%s' "$out" | grep -q 'pull_request-triggered' && echo 1 || echo 0)"

# --- a branch identical to its base --------------------------------------

git -C "$repo" checkout -q -b empty origin/main
out="$(run_step main)"; rc=$?
check "a branch with no changes against its base fails" "1" "$rc"
check "and names the base it compared against" "1" \
	"$(printf '%s' "$out" | grep -q 'empty diff against main' && echo 1 || echo 0)"

# --- a branch that changes something -------------------------------------

echo two > "$repo/f"
git -C "$repo" add -A && git -C "$repo" commit -qm change
out="$(run_step main)"; rc=$?
check "a branch that changes a file passes" "0" "$rc"

# --- a commit that changes nothing is still an empty diff ----------------
#
# `--allow-empty` produces a commit with no diff. The gate compares trees, not
# commit counts, so this must fail: a pull request whose only commit is empty
# changes nothing no matter how many commits it carries.

git -C "$repo" checkout -q -b hollow origin/main
git -C "$repo" commit -q --allow-empty -m "no changes"
out="$(run_step main)"; rc=$?
check "a branch whose only commit is empty still fails" "1" "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
