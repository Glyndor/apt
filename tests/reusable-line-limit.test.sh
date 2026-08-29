#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-line-limit.yml.
#
# The lint added in `scripts/lint-workflow-shell.sh` checks that this workflow`\s
# shell is well formed. It cannot check that the shell does what the gate claims,
# and a counter that counts the wrong files is perfectly well formed. These tests
# plant a file that must be reported and require red, which is the only way to
# tell a working limit from one that is looking at nothing.
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

WORKFLOW="$HERE/.github/workflows/reusable-line-limit.yml"
step_script "$WORKFLOW" "Check file lengths" > "$WORK/step.sh"

# A git repository, because the step enumerates with `git ls-files -z` and so
# only ever sees tracked files.
sandbox() { # $1=path  $2..=files to create as "name:lines"
	local dir="$1"; shift
	rm -rf "$dir"; mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" config user.email t@example.invalid
	git -C "$dir" config user.name t
	local spec name lines
	for spec in "$@"; do
		name="${spec%%:*}"; lines="${spec##*:}"
		mkdir -p "$dir/$(dirname "$name")"
		yes 'x' | head -n "$lines" > "$dir/$name"
	done
	git -C "$dir" add -A
	# --allow-empty: some cases seed no tracked files on purpose, and a git
	# error on stderr would read as a test failure rather than as the setup
	# doing exactly what the case asks for.
	git -C "$dir" commit -qm seed --allow-empty >/dev/null 2>&1
}

run_step() { # $1=dir  $2=extensions  -> prints output, sets rc
	( cd "$1" && HARD=500 SOFT=300 EXTS="$2" EXCLUDE="" bash "$WORK/step.sh" 2>&1 )
}

SH_EXTS="rs go ts tsx js jsx mjs cjs py sh astro vue svelte"
YML_EXTS="$SH_EXTS yml yaml"

# --- a shell script over the hard limit must fail -------------------------

sandbox "$WORK/a" "scripts/huge.sh:600"
out="$(run_step "$WORK/a" "$SH_EXTS")"; rc=$?
check "a 600-line shell script fails the hard limit" "1" "$rc"
check "and the error names the file" "1" \
	"$(printf '%s' "$out" | grep -q 'scripts/huge.sh' && echo 1 || echo 0)"
check "and gives the count it measured" "1" \
	"$(printf '%s' "$out" | grep -q '600 code lines' && echo 1 || echo 0)"

# --- comments and blanks are not code ------------------------------------

sandbox "$WORK/b"
mkdir -p "$WORK/b/scripts"
{ printf '#!/bin/sh\n'; for _ in $(seq 700); do printf '# comment\n\n'; done; } > "$WORK/b/scripts/comments.sh"
git -C "$WORK/b" add -A && git -C "$WORK/b" commit -qm comments
out="$(run_step "$WORK/b" "$SH_EXTS")"; rc=$?
check "1400 lines of comments and blanks are not 1400 code lines" "0" "$rc"

# --- the blindness this gate had until 2026-08-29 ------------------------
#
# A workflow over the limit passes when `yml` is absent from the extension
# list, and the success line is identical to a real pass. That is not a bug in
# the step, it is the step being told what to look at; the assertion exists so
# that if the extension list is ever narrowed again, a test says so instead of
# the check quietly reporting success on a file it never opened.

sandbox "$WORK/c" ".github/workflows/huge.yml:600"
out="$(run_step "$WORK/c" "$SH_EXTS")"; rc=$?
check "a 600-line workflow passes when yml is not in the extension list" "0" "$rc"
check "and says everything is within the limit, indistinguishably from a real pass" "1" \
	"$(printf '%s' "$out" | grep -q 'within the' && echo 1 || echo 0)"

out="$(run_step "$WORK/c" "$YML_EXTS")"; rc=$?
check "the same file fails once yml is in the list" "1" "$rc"
check "and the error names the workflow" "1" \
	"$(printf '%s' "$out" | grep -q '.github/workflows/huge.yml' && echo 1 || echo 0)"

# --- vendored and minified files are skipped by design -------------------

sandbox "$WORK/d" "vendor/big.sh:600" "app.min.js:600"
out="$(run_step "$WORK/d" "$SH_EXTS")"; rc=$?
check "vendored and minified files are exempt" "0" "$rc"

# --- an untracked file is invisible, because git decides the file list ----

sandbox "$WORK/e"
yes 'x' | head -n 600 > "$WORK/e/untracked.sh"
out="$(run_step "$WORK/e" "$SH_EXTS")"; rc=$?
check "an untracked file is not checked" "0" "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
