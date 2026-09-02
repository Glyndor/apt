#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-dco.yml.
#
# The DCO gate is the only thing standing behind the sign-off attestation, and
# on the tap and the bucket it is not even a required check, so it relies on
# being correct rather than on being enforced. These tests give it real commits
# and require it to report the ones without a trailer.
#
# It reads BASE_SHA and HEAD_SHA from the environment. GitHub fills those from
# the event payload, which is the whole of its dependency on GitHub: a local
# repository with two commits exercises the same code.
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

WORKFLOW="$HERE/.github/workflows/reusable-dco.yml"
step_script "$WORKFLOW" "Verify Signed-off-by trailers" > "$WORK/step.sh"

repo="$WORK/r"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
commit() { # $1=message  $2=signed|unsigned
	echo "$RANDOM" > "$repo/f"
	git -C "$repo" add -A
	if [ "$2" = signed ]; then
		git -C "$repo" commit -qm "$1" -s
	else
		git -C "$repo" commit -qm "$1"
	fi
	git -C "$repo" rev-parse HEAD
}

run_step() { # $1=base $2=head
	( cd "$repo" && BASE_SHA="$1" HEAD_SHA="$2" bash "$WORK/step.sh" 2>&1 )
}

base="$(commit base signed)"

# --- a signed range passes -----------------------------------------------

a="$(commit "first" signed)"
b="$(commit "second" signed)"
out="$(run_step "$base" "$b")"; rc=$?
check "a range where every commit is signed off passes" "0" "$rc"
check "and says so" "1" \
	"$(printf '%s' "$out" | grep -q 'All commits carry a Signed-off-by trailer' && echo 1 || echo 0)"

# --- one unsigned commit fails, and is named -----------------------------

bad="$(commit "third, unsigned" unsigned)"
out="$(run_step "$base" "$bad")"; rc=$?
check "one commit without a trailer fails the range" "1" "$rc"
check "and the error names that commit" "1" \
	"$(printf '%s' "$out" | grep -q "$bad" && echo 1 || echo 0)"
check "and not the signed commits before it" "0" \
	"$(printf '%s' "$out" | grep -c "$a")"
check "and tells the author how to fix it" "1" \
	"$(printf '%s' "$out" | grep -q 'git commit -s' && echo 1 || echo 0)"

# --- an empty range passes, because there is nothing to attest -----------

out="$(run_step "$bad" "$bad")"; rc=$?
check "an empty range passes" "0" "$rc"

# --- a trailer is matched case-insensitively -----------------------------

echo "$RANDOM" > "$repo/f"
git -C "$repo" add -A
git -C "$repo" commit -qm "fourth

signed-off-by: Someone <s@example.invalid>"
lower="$(git -C "$repo" rev-parse HEAD)"
out="$(run_step "$bad" "$lower")"; rc=$?
check "a lowercase signed-off-by trailer is accepted" "0" "$rc"

# ===========================================================================
# Detect evil merges
# ===========================================================================
#
# A merge commit's tree must equal the clean merge of its two parents. The
# step had no test: it is the check that catches content smuggled into a
# hand-edited merge, which is the one shape of change that never appears as
# its own reviewed, signed commit.
step_script "$WORKFLOW" "Detect evil merges" > "$WORK/merges.sh"
check "the evil-merge step was extracted from the workflow" "1" \
	"$(grep -c 'merge-tree' "$WORK/merges.sh" | awk '{print ($1>0)}')"

mrepo="$WORK/m"
git init -q -b main "$mrepo"
git -C "$mrepo" config user.email t@example.invalid
git -C "$mrepo" config user.name t
mcommit() { # $1=file $2=content $3=message -> sha
	printf '%s\n' "$2" > "$mrepo/$1"
	git -C "$mrepo" add -A
	git -C "$mrepo" commit -qm "$3" -s
	git -C "$mrepo" rev-parse HEAD
}
run_merges() { # $1=base $2=head
	( cd "$mrepo" && BASE_SHA="$1" HEAD_SHA="$2" bash "$WORK/merges.sh" 2>&1 )
}

mbase="$(mcommit a one "base")"

# --- a clean two-parent merge passes -------------------------------------
git -C "$mrepo" checkout -q -b topic
mcommit b two "topic work" >/dev/null
git -C "$mrepo" checkout -q main
mcommit c three "main work" >/dev/null
git -C "$mrepo" merge -q --no-ff --no-edit topic
clean="$(git -C "$mrepo" rev-parse HEAD)"
out="$(run_merges "$mbase" "$clean")"; rc=$?
check "a clean two-parent merge passes" "0" "$rc"

# --- a merge whose tree carries content in neither parent fails ----------
git -C "$mrepo" checkout -q -b topic2 "$mbase"
mcommit d four "more topic work" >/dev/null
git -C "$mrepo" checkout -q main
git -C "$mrepo" merge -q --no-ff --no-edit topic2
printf 'smuggled\n' > "$mrepo/e"
git -C "$mrepo" add -A
git -C "$mrepo" commit -q --amend --no-edit
evil="$(git -C "$mrepo" rev-parse HEAD)"
out="$(run_merges "$clean" "$evil")"; rc=$?
check "a merge carrying content present in neither parent fails" "1" "$rc"
check "and it is refused as a tree mismatch, not something else" "1" \
	"$(printf '%s' "$out" | grep -q 'does not match the clean merge of its parents' && echo 1 || echo 0)"
check "and the merge commit is named" "1" \
	"$(printf '%s' "$out" | grep -q "$evil" && echo 1 || echo 0)"
check "and it is the only merge reported" "1" "$(printf '%s' "$out" | grep -c '::error')"

# --- an octopus merge is rejected rather than assumed safe ---------------
git -C "$mrepo" checkout -q -b octo1 "$evil"; mcommit f1 x "octo one" >/dev/null
git -C "$mrepo" checkout -q -b octo2 "$evil"; mcommit f2 y "octo two" >/dev/null
git -C "$mrepo" checkout -q main
git -C "$mrepo" merge -q --no-ff --no-edit octo1 octo2
octo="$(git -C "$mrepo" rev-parse HEAD)"
out="$(run_merges "$evil" "$octo")"; rc=$?
check "an octopus merge fails" "1" "$rc"
check "and it is refused for its parent count, not its tree" "1" \
	"$(printf '%s' "$out" | grep -q 'octopus merge is rejected' && echo 1 || echo 0)"

# --- a hand-resolved conflict fails closed -------------------------------
git -C "$mrepo" checkout -q -b conflict "$octo"
mcommit a left "left edit" >/dev/null
git -C "$mrepo" checkout -q main
mcommit a right "right edit" >/dev/null
git -C "$mrepo" merge -q --no-ff --no-edit conflict >/dev/null 2>&1 || true
printf 'resolved\n' > "$mrepo/a"
git -C "$mrepo" add -A
git -C "$mrepo" -c core.editor=true commit -q --no-edit
resolved="$(git -C "$mrepo" rev-parse HEAD)"
out="$(run_merges "$octo" "$resolved")"; rc=$?
check "a hand-resolved conflicting merge fails closed" "1" "$rc"
check "and says it could not be automatically verified" "1" \
	"$(printf '%s' "$out" | grep -q 'cannot be automatically verified' && echo 1 || echo 0)"

# --- a range with no merge commit passes -------------------------------
lin="$(mcommit g z "linear")"
rc=0; run_merges "$resolved" "$lin" >/dev/null || rc=$?
check "a range with no merge commit passes" "0" "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
