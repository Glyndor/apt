#!/usr/bin/env bash
#
# tests/fixtures/ci/step-script.sh reads the shell of one workflow step for the
# suites that run it as it ships. A reader that gives up on a form of the `run:`
# header, or that returns an empty script for a step it did not find, makes those
# suites run nothing and pass, so each form is read here and each failure is loud.
#
# Every form is written as a workflow and the printed script is compared with what
# the shell should receive; the missing step and the one-line step are refused by
# their message, and a step that follows another is not read into it.
#
# Requires: python3.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# shellcheck disable=SC1091 # the fixture under test
. "$HERE/tests/fixtures/ci/step-script.sh"

plant() { # $1=name; the workflow text on stdin
	cat > "$WORK/$1.yml"
}
read_step() { # $1=file name $2=step name -> out, rc, err
	out="$(step_script "$WORK/$1.yml" "$2" 2>"$WORK/err")"
	rc=$?
	err="$(cat "$WORK/err")"
}

plant forms <<'YAML'
jobs:
  j:
    steps:
      - name: Pipe
        run: |
          echo one
          echo two
      - name: Strip
        run: |-
          echo three
      - name: Keep
        run: |+
          echo four
      - name: Indent
        run: |2
            echo five
      - name: Commented
        run: | # a note on the header
          echo six
      - name: Item
        env:
          X: y
        run: |
          echo seven

          echo after-blank
      - name: Folded
        run: >-
          echo eight
          nine

          echo ten
      - uses: actions/checkout@0000000000000000000000000000000000000000 # v1
      - name: Last
        run: |
          echo last
YAML
read_step forms "Pipe";      check "a literal block is read as it is written" "echo one
echo two" "$out"
read_step forms "Strip";     check "a block that strips its trailing newlines is read" "echo three" "$out"
read_step forms "Keep";      check "a block that keeps its trailing newlines is read" "echo four" "$out"
read_step forms "Indent";    check "a block with an explicit indentation indicator is read" "  echo five" "$out"
read_step forms "Commented"; check "a header with a comment after it is read" "echo six" "$out"
read_step forms "Item";      check "a step with other keys before run: is read, and a blank line inside the body stays" "echo seven

echo after-blank" "$out"
read_step forms "Folded";    check "a folded block is printed as the shell receives it, a blank line kept" "echo eight nine

echo ten" "$out"
read_step forms "Last";      check "the last step of the file is read" "echo last" "$out"
read_step forms "Pipe";      check "a step is not read into the one that follows it" "0" "$(printf '%s\n' "$out" | grep -c 'three')"

read_step forms "Absent"
check "a step that is not in the workflow is an error" "1" "$rc"
check "and it says which step" "1" "$(printf '%s\n' "$err" | grep -c "no step named 'Absent'")"
check "and prints no script" "" "$out"

plant oneline <<'YAML'
jobs:
  j:
    steps:
      - name: Short
        run: echo hi
      - name: Next
        run: |
          echo next
YAML
read_step oneline "Short"
check "a one-line run: is an error, not the body of the next step" "1" "$rc"
check "and says the step has no block scalar" "1" "$(printf '%s\n' "$err" | grep -c 'has no block scalar run:')"
check "and does not print the next step's script" "" "$out"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
