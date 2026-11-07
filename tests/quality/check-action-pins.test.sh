#!/usr/bin/env bash
#
# Tests for scripts/quality/check-action-pins.sh: a remote `uses:` must be
# pinned by a 40-character commit SHA. Each fixture is a small repository root
# with one workflow, so a refusal is for the reference the fixture plants and no
# other. The reading of a workflow is not a YAML parser, so the cases that could
# fool a line reader are here too: the word `uses:` inside a shell script, a
# quoted value, a flow mapping and a block scalar.
#
# Requires: nothing beyond bash, awk and coreutils.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$HERE/scripts/quality/check-action-pins.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1

# root <name>: a fresh repository root; the workflow text comes on stdin.
root() {
	local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/.github/workflows"
	cat > "$d/.github/workflows/w.yml"
	echo "$d"
}
run() { "$CHECK" "$1" >"$WORK/out" 2>&1; }
said() { grep -qF -- "$1" "$WORK/out" && echo 1 || echo 0; }
rc_of() { local rc=0; run "$1" || rc=$?; echo "$rc"; }

R="$(root pinned <<EOF2
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA # v7.0.1
EOF2
)"
check "control: a SHA-pinned action passes" "0" "$(rc_of "$R")"

R="$(root tag <<'EOF2'
jobs:
  a:
    steps:
      - uses: actions/checkout@v4
EOF2
)"
check "a tag is refused" "1" "$(rc_of "$R")"
check "and the message names the file and the line" "1" "$(said 'w.yml:4')"
# shellcheck disable=SC2016 # the backticks are the literal text of the message
check "and says what it was pinned to" "1" "$(said 'pinned to `v4`')"

R="$(root branch <<'EOF2'
jobs:
  a:
    steps:
      - uses: actions/checkout@main
EOF2
)"
check "a branch is refused" "1" "$(rc_of "$R")"

R="$(root bare <<'EOF2'
jobs:
  a:
    steps:
      - uses: actions/checkout
EOF2
)"
check "a reference with no pin at all is refused" "1" "$(rc_of "$R")"
check "and the message says it carries no pin" "1" "$(said 'carries no pin')"

R="$(root short <<'EOF2'
jobs:
  a:
    steps:
      - uses: actions/checkout@3d3c42e
EOF2
)"
check "an abbreviated SHA is refused" "1" "$(rc_of "$R")"

R="$(root upper <<'EOF2'
jobs:
  a:
    steps:
      - uses: actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1
EOF2
)"
check "an upper-case SHA is refused" "1" "$(rc_of "$R")"

R="$(root local <<'EOF2'
jobs:
  a:
    uses: ./.github/workflows/reusable.yml
  b:
    steps:
      - uses: ./.github/actions/thing
      - uses: docker://alpine:3
EOF2
)"
check "local actions, local reusables and containers are out of scope" "0" "$(rc_of "$R")"

R="$(root reusable <<'EOF2'
jobs:
  a:
    uses: Glyndor/github-config/.github/workflows/x.yml@main
EOF2
)"
check "a remote reusable workflow is checked too" "1" "$(rc_of "$R")"

R="$(root quoted <<'EOF2'
jobs:
  a:
    steps:
      - uses: "actions/checkout@v4"
EOF2
)"
check "a quoted reference is read and refused" "1" "$(rc_of "$R")"

R="$(root flow <<'EOF2'
jobs:
  a:
    steps:
      - { uses: actions/checkout@v4, with: { x: 1 } }
EOF2
)"
check "a flow mapping is read and refused" "1" "$(rc_of "$R")"

R="$(root prose <<EOF2
jobs:
  a:
    steps:
      # uses: actions/checkout@v4 is only a comment
      - uses: actions/checkout@$SHA
      - run: echo "grep uses: in the workflows" && grep -n 'uses:' x
      - run: |
          grep -n 'uses: actions/checkout@v4' .github/workflows/*.yml
EOF2
)"
check "the word uses: in a comment or a shell script is not a reference" "0" "$(rc_of "$R")"

R="$(root scalar <<'EOF2'
jobs:
  a:
    steps:
      - uses: >-
          actions/checkout@v4
EOF2
)"
check "a reference in a block scalar is read and refused" "1" "$(rc_of "$R")"

R="$(root two <<EOF2
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA
      - uses: actions/cache@v6
      - uses: actions/setup-go@v7
EOF2
)"
rc_of "$R" >/dev/null
check "every unpinned reference is reported, not just the first" "2" "$(grep -c '^::error file=' "$WORK/out")"

# Two references on one line, in a flow sequence: the second one is held to the
# pin as well (issue #371). The control is a copy of the checker that stops at
# the first reference of a line, as it did.
R="$(root flow-two <<EOF2
jobs:
  a:
    steps: [{uses: actions/checkout@$SHA}, {uses: actions/cache@v4}]
EOF2
)"
check "a second reference on the same line is refused" "1" "$(rc_of "$R")"
check "and it is reported once, for the unpinned one" "1" "$(grep -c '^::error file=' "$WORK/out")"
R="$(root flow-pinned <<EOF2
jobs:
  a:
    steps: [{uses: actions/checkout@$SHA}, {uses: actions/cache@$SHA}]
EOF2
)"
check "two pinned references on one line pass" "0" "$(rc_of "$R")"
python3 -I - "$CHECK" "$WORK/check-first-only.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "\t\t\t\trest = substr(rest, pos + len)\n\t\t\t}\n\t\t}\n\t\tEND {"
assert old in s
open(sys.argv[2], "w").write(s.replace(old, "\t\t\t\tbreak\n\t\t\t}\n\t\t}\n\t\tEND {", 1))
PY
chmod +x "$WORK/check-first-only.sh"
R="$(root flow-two-cut <<EOF2
jobs:
  a:
    steps: [{uses: actions/checkout@$SHA}, {uses: actions/cache@v4}]
EOF2
)"
rc=0; "$WORK/check-first-only.sh" "$R" >/dev/null 2>&1 || rc=$?
check "reading only the first reference of a line lets the second through (the refusal is the loop's)" "0" "$rc"

# A quoted key: the opening quote used to defeat the test on what precedes the
# key, so the extractor found no reference and another normal workflow was
# enough to pass the empty-inventory guard.
R="$(root quoted-key-dq <<EOF2
jobs:
  a:
    steps:
      - "uses": actions/checkout@v4
EOF2
)"
check "a double-quoted uses key with a tag is refused" "1" "$(rc_of "$R")"
R="$(root quoted-key-sq <<EOF2
jobs:
  a:
    steps:
      - 'uses': actions/checkout@v4
EOF2
)"
check "a single-quoted uses key with a tag is refused" "1" "$(rc_of "$R")"
R="$(root quoted-key-ok <<EOF2
jobs:
  a:
    steps:
      - "uses": actions/checkout@$SHA
EOF2
)"
check "a double-quoted uses key with a SHA pin passes" "0" "$(rc_of "$R")"
python3 -I - "$CHECK" "$WORK/check-unquoted-key.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "while (match(rest, /[\"'\"'\"']?uses"
assert old in s
open(sys.argv[2], "w").write(s.replace(old, "while (match(rest, /uses", 1))
PY
chmod +x "$WORK/check-unquoted-key.sh"
check "the quoted-key control changed the script" "1" "$(cmp -s "$CHECK" "$WORK/check-unquoted-key.sh" && echo 0 || echo 1)"
R="$(root quoted-key-cut <<EOF2
jobs:
  a:
    steps:
      - "uses": actions/checkout@v4
      - uses: actions/cache@$SHA
EOF2
)"
rc=0; "$WORK/check-unquoted-key.sh" "$R" >/dev/null 2>&1 || rc=$?
check "reading only bare keys lets the quoted unpinned one through (the refusal is the pattern's)" "0" "$rc"

R="$(mktemp -d -p "$WORK")"
mkdir -p "$R/.github/workflows"
check "a root with no workflow file is an error, not a pass" "1" "$(rc_of "$R")"

check "the real workflows of this repository pass" "0" "$(rc_of "$HERE")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
