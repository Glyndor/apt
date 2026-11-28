#!/usr/bin/env bash
#
# Pull the shell of one step out of a workflow so a test can run it as it ships,
# instead of running a copy of it that can drift. Sourced, never run: it defines
# one function, and it is not named *.test.sh because it is not a suite
# (tests/ci/suites/step-script.test.sh is).
#
#   step_script_of <workflow file> <text of the step's name>
#   step_script    <workflow file> <text of the step's name>   (the same, for the suites that name the workflow)
#
# The step is the first whose `name:` line contains the text. Its `run:` body is
# printed with its indentation removed, ready for bash. The key can be a list item
# (`- run: |`), and the block scalar can be any of the header forms YAML has:
# `|`, `|-`, `|+`, `|2` and the folded `>` family, with a comment after the header.
# A folded body is printed as the shell receives it: its lines joined with a space,
# a blank line kept as a line break. One-line `run: cmd` steps are not read, because
# no suite needs them: a step that is not found, or whose body is not a block scalar,
# is an error with a message on stderr and a non-zero status, not an empty script.
#
# The reader used to be written out in nine places that looked for the literal
# `run: |` and a fixed indent, so a workflow that moved to `run: |-` raised in the
# copies nobody had updated.
#
# Requires: python3.

step_script() { step_script_of "$@"; }

step_script_of() { # $1=workflow path  $2=step name substring
	python3 -I - "$1" "$2" <<'PY'
import re
import sys

path, name = sys.argv[1:3]
lines = open(path, encoding="utf-8").read().splitlines()
start = next((i for i, line in enumerate(lines) if "name: " + name in line), None)
if start is None:
    sys.exit("step_script: no step named %r in %s" % (name, path))
header = re.compile(r"^(\s*)(?:-\s+)?run:\s*([|>])([-+0-9]*)\s*(?:#.*)?$")
run = style = key = explicit = None
for i in range(start + 1, len(lines)):
    found = header.match(lines[i])
    if found:
        run, style, key = i, found.group(2), lines[i].index("run:")
        digit = re.search(r"[0-9]", found.group(3))
        explicit = int(digit.group()) if digit else None
        break
    if re.match(r"^\s*-\s+(name|uses):", lines[i]) and i > start + 1:
        break
if run is None:
    sys.exit("step_script: the step %r of %s has no block scalar run:" % (name, path))
body = []
# An indentation indicator (`|2`) fixes the body's indentation relative to the key;
# without one it is the indentation of the first line that has text.
indent = key + explicit if explicit else None
for line in lines[run + 1:]:
    if not line.strip():
        body.append("")
        continue
    width = len(line) - len(line.lstrip(" "))
    if width <= key:
        break
    if indent is None:
        indent = width
    body.append(line[indent:] if width >= indent else line.lstrip(" "))
if style == ">":
    folded, pending = [], ""
    for line in body:
        if not line:
            if pending:
                folded.append(pending)
                pending = ""
            folded.append("")
        else:
            pending = line if not pending else pending + " " + line
    if pending:
        folded.append(pending)
    body = folded
print("\n".join(body))
PY
}
