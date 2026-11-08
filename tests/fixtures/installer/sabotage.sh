#!/usr/bin/env bash
# Helpers for suites that pair a case with a copy of the installer template with
# one guard removed. Sourced after fixture.sh, which owns $WORK, $BIN and
# $TEMPLATE.
# shellcheck disable=SC2154 # the sourced fixture owns these variables

ORIG="$TEMPLATE"

# A copy of the template with every $1 (exact text) replaced by $2. A miss
# aborts the suite: a control that changes nothing proves nothing.
cut_template() { # $1=old $2=new $3=name -> path
	python3 - "$ORIG" "$WORK/cut-$3.sh" "$1" "$2" <<'PY' || exit 1
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
assert old in s, "guard text not found: " + old
open(dst, "w").write(s.replace(old, new))
PY
	echo "$WORK/cut-$3.sh"
}

# A PATH directory made of every executable on the machine except $1, with the
# fixture stubs first. Removing a command from PATH is otherwise impossible
# without removing the ones the installer needs next.
path_without() { # $1=command -> directory
	local dir="$WORK/path-without-$1" f
	mkdir -p "$dir"
	for f in /usr/bin/*; do
		[ "${f##*/}" = "$1" ] || ln -sf "$f" "$dir/${f##*/}"
	done
	for f in "$BIN"/*; do
		[ "${f##*/}" = "$1" ] || ln -sf "$f" "$dir/${f##*/}"
	done
	echo "$dir"
}

# run_installer with another template; the caller's template is put back.
with_template() { # $1=template  rest: run_installer arguments
	local t="$1"; shift
	TEMPLATE="$t"; run_installer "$@"; local rc=$?
	TEMPLATE="$ORIG"; return "$rc"
}
