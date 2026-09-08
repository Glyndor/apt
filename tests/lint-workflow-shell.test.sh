#!/usr/bin/env bash
# Tests for scripts/lint-workflow-shell.sh.
#
# The point of the script is that a linter which inspected nothing prints the
# same success line as one that inspected everything, so the tests that matter
# here are the ones that plant a violation and require red, and the one that
# hands it a tree with no workflows and requires red for that too. A test that
# only ran it against the real tree and checked for exit 0 would pass just as
# happily against a script that returns 0 unconditionally.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/scripts/lint-workflow-shell.sh"

pass=0
fail=0

check() { # $1=description $2=expected $3=actual
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok   - $1"
	else
		fail=$((fail + 1))
		echo "FAIL - $1: expected '$2', got '$3'"
	fi
}

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "FAIL - shellcheck is not on PATH; these tests cannot run" >&2
	exit 1
fi

# --- the repository's own workflows --------------------------------------

out="$("$SCRIPT" style 2>&1)"
rc=$?
check "this repository's embedded shell is clean at the strictest severity" "0" "$rc"

# A count of zero would pass the exit-code assertion above while proving
# nothing, which is the whole failure mode this script exists to close.
blocks="$(printf '%s' "$out" | sed -n 's/^\([0-9]\+\) embedded.*/\1/p')"
check "and it reports how many blocks it inspected" "1" \
	"$([ -n "$blocks" ] && echo 1 || echo 0)"
check "and that count is greater than zero" "1" \
	"$([ "${blocks:-0}" -gt 0 ] && echo 1 || echo 0)"

# --- a planted violation must turn it red --------------------------------

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/.github/workflows"
cp "$SCRIPT" "$work/scripts/"

cat >"$work/.github/workflows/planted.yml" <<'YML'
name: planted
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: a violation shellcheck is certain to catch
        run: |
          set -euo pipefail
          rm -rf $UNQUOTED/*
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a planted violation fails" "1" "$rc"
check "and names the rule it tripped" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"

# The finding is useless if it points at a temporary file, and misleading if
# it points at the wrong line of the right file. `run: |` is line 8 of the
# workflow above and the offending command is line 10.
check "and reports it against the workflow, not the temporary copy" "1" \
	"$(printf '%s' "$out" | grep -q 'file=.github/workflows/planted.yml' && echo 1 || echo 0)"
check "and on the line the offending command is on" "1" \
	"$(printf '%s' "$out" | grep -q 'line=10' && echo 1 || echo 0)"

# --- an empty tree must turn it red too ----------------------------------

rm -f "$work/.github/workflows/planted.yml"
out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a tree with no run: blocks fails rather than reporting success" "1" "$rc"
check "and says the extractor found nothing" "1" \
	"$(printf '%s' "$out" | grep -q 'found no' && echo 1 || echo 0)"

# --- a single-line `run:` is shell too -----------------------------------
#
# This form was skipped when the script was written, and the check reported how
# many it was skipping rather than reading them. The cases below are what makes
# that closed rather than merely announced.

cat >"$work/.github/workflows/oneline.yml" <<'YML'
name: oneline
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: a single-line run with a violation
        run: rm -rf $UNQUOTED/*
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a violation in a single-line run: fails" "1" "$rc"
check "and reports it on that line of the workflow" "1" \
	"$(printf '%s' "$out" | grep -q 'file=.github/workflows/oneline.yml,line=8' && echo 1 || echo 0)"

# A quoted scalar is the same shell with YAML quoting around it, and unwrapping
# it wrongly would either miss the finding or report on the quotes.
cat >"$work/.github/workflows/oneline.yml" <<'YML'
name: oneline
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: a quoted single-line run that is correct shell
        run: "echo hello"
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a quoted single-line run: is unwrapped and passes" "0" "$rc"
rm -f "$work/.github/workflows/oneline.yml"

# --- a GitHub expression is not a finding --------------------------------

cat >"$work/.github/workflows/expressions.yml" <<'YML'
name: expressions
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: quoted expression, which is correct shell
        run: |
          set -euo pipefail
          echo "${{ github.sha }}"
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a quoted GitHub expression is not reported as a shell problem" "0" "$rc"

# --- every YAML block scalar header for `run:` is recognised ------------
#
# The extractor only used to recognise `run: |` and single-line `run: cmd`,
# so a chomped `run: |-` slipped between them: its body was never linted
# and never counted, which is the failure mode the "found no blocks" guard
# exists to catch (the guard can't fire when 34 other blocks satisfy it,
# so the chomped one simply disappears). The cases below pin each shape.

# Earlier sections leave their fixtures in the tree; clear them so each
# case below measures exactly the workflow it planted.
rm -f "$work/.github/workflows/expressions.yml"

cat >"$work/.github/workflows/chomp.yml" <<'YML'
name: chomp
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: chomped block with violation
        run: |-
          set -euo pipefail
          rm -rf $UNQUOTED/*
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
# The exit-code assertion alone is not the discriminator: the broken
# extractor also exits 1 (with "found no blocks"). The SC2115 finding on
# the workflow line is what proves the body actually reached shellcheck.
check "a dirty run: |- block trips shellcheck" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"
check "and reports it against the right workflow and line" "1" \
	"$(printf '%s' "$out" | grep -q 'file=.github/workflows/chomp.yml,line=10' && echo 1 || echo 0)"

# The case is about the header, not the body: the same body under `run: |`
# must reach shellcheck and trip the same rule, so a regression in the body
# extractor (which would change findings under both headers) goes red here.
cat >"$work/.github/workflows/pipe.yml" <<'YML'
name: pipe
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: pipe block with violation
        run: |
          set -euo pipefail
          rm -rf $UNQUOTED/*
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
check "the same body under run: | trips the same rule" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"
check "and reports it on the same line" "1" \
	"$(printf '%s' "$out" | grep -q 'file=.github/workflows/pipe.yml,line=10' && echo 1 || echo 0)"

rm -f "$work/.github/workflows/chomp.yml" "$work/.github/workflows/pipe.yml"

# `run: |+` is a keep block and carries the same shell as `run: |`.
cat >"$work/.github/workflows/keep.yml" <<'YML'
name: keep
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: keep block with violation
        run: |+
          set -euo pipefail
          rm -rf $UNQUOTED/*
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
check "a dirty run: |+ block trips shellcheck" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"
rm -f "$work/.github/workflows/keep.yml"

# A folded (`run: >`) block joins its lines into spaces, so the shell it
# would run is not the shell it looks like; the extractor counts it but
# does not lint it. A workflow whose ONLY step is a folded block is the
# case that decides whether the success line is honest.
cat >"$work/.github/workflows/folded.yml" <<'YML'
name: folded
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: folded block
        run: >
          echo folded
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a run: > block does not abort the extractor" "0" "$rc"
check "and the success line counts it" "1" \
	"$(printf '%s' "$out" | grep -q '^1 embedded' && echo 1 || echo 0)"
rm -f "$work/.github/workflows/folded.yml"

# All three recognised shapes together: the count must add up so an
# operator reading the success line knows nothing was silently skipped.
cat >"$work/.github/workflows/shapes.yml" <<'YML'
name: shapes
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: clip
        run: |
          echo clip
      - name: keep
        run: |+
          echo keep
      - name: folded
        run: >
          echo folded
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
# The exit-code assertion is not the discriminator for this case (broken
# code lints the `run: |` step, finds nothing, still exits 0 with the
# wrong count). The number in the success line is what proves nothing
# was silently skipped.
check "and the success line says three" "1" \
	"$(printf '%s' "$out" | grep -q '^3 embedded' && echo 1 || echo 0)"
rm -f "$work/.github/workflows/shapes.yml"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
