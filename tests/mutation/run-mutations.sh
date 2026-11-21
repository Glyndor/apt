#!/usr/bin/env bash
# The catalogue of mutations: every entry breaks one guard of the scripts of this
# repository on purpose and names the tests that must notice. A guard that no test
# notices is decoration, and reading the suite cannot tell which ones are
# decoration: the only way to know is to break them and watch it go red.
#
#   run-mutations.sh            every entry of the catalogue
#   run-mutations.sh --list     the ids, one per line
#   run-mutations.sh <id>       one entry
#
# Options:
#   --repo <path>      the repository to copy and mutate (default: this repository)
#   --catalog <path>   the catalogue to read (default: <repo>/tests/mutation/catalog.txt)
#
# THE COPY CARRIES NO GIT METADATA
#
# The copy is made with `git archive HEAD`, so it holds no .git directory: a
# suite that reads the history of the repository fails there whatever the mutant
# is, and it would count as a kill that never happened. Two of them are
# excluded by name, because no runner can hand that copy a history: the suite
# runner, which reads the base commit to scope the suites, and the
# editorconfig gate, which walks `git ls-files`. Any OTHER suite that fails in
# a pristine copy is excluded as well, measured once per suite: a suite that
# cannot pass without the mutant cannot tell a mutant from an unmutated tree.
#
# The suites left out on the machine this catalogue was measured on, and why,
# are named in the catalogue.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CATALOG=""
LIST=0
ONLY=()

# Suites that need the git metadata the copy does not have. Excluded by name:
# they fail in every copy, on every machine, and measuring them per run would
# only re-measure a fact that cannot change.
ALWAYS_EXCLUDED="tests/ci/suites/check-suite-completeness.test.sh
tests/quality/check-editorconfig.test.sh"

usage() {
	cat <<'EOF'
usage: run-mutations.sh [--repo <path>] [--catalog <path>] [--list] [<id>...]
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		REPO="${2:?--repo needs a path}"
		shift 2
		;;
	--catalog)
		CATALOG="${2:?--catalog needs a path}"
		shift 2
		;;
	--list)
		LIST=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		echo "run-mutations.sh: unknown option $1" >&2
		usage >&2
		exit 2
		;;
	*)
		ONLY+=("$1")
		shift
		;;
	esac
done

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || {
	echo "run-mutations.sh: no repository at $REPO" >&2
	exit 2
}
[ -n "$CATALOG" ] || CATALOG="$REPO/tests/mutation/catalog.txt"
[ -f "$CATALOG" ] || {
	echo "run-mutations.sh: no catalogue at $CATALOG" >&2
	exit 2
}

# --- the catalogue ---------------------------------------------------------------
# One entry per line, five fields separated by tabs: the id, the file to mutate,
# the exact text to replace, the text that replaces it and the tests of tests/
# that must fail. The text to replace has to appear exactly once in the file: a
# text that appears nowhere changes nothing and proves nothing, and one that
# appears twice is ambiguous.
IDS=()
FILES=()
OLDS=()
NEWS=()
TESTS=()

while IFS= read -r line || [ -n "$line" ]; do
	trimmed="${line#"${line%%[![:space:]]*}"}"
	[ -n "$trimmed" ] || continue
	case "$trimmed" in '#'*) continue ;; esac
	tabs="${line//[^$'\t']/}"
	if [ "${#tabs}" -ne 4 ]; then
		echo "run-mutations.sh: the catalogue line must hold exactly four tabs: $line" >&2
		exit 2
	fi
	f1="${line%%$'\t'*}"
	r="${line#*$'\t'}"
	f2="${r%%$'\t'*}"
	r="${r#*$'\t'}"
	f3="${r%%$'\t'*}"
	r="${r#*$'\t'}"
	f4="${r%%$'\t'*}"
	f5="${r#*$'\t'}"
	if [ -z "$f1" ] || [ -z "$f2" ] || [ -z "$f3" ] || [ -z "$f4" ] || [ -z "$f5" ]; then
		echo "run-mutations.sh: the catalogue line has an empty field: $line" >&2
		exit 2
	fi
	IDS+=("$f1")
	FILES+=("$f2")
	OLDS+=("$f3")
	NEWS+=("$f4")
	TESTS+=("$f5")
done < "$CATALOG"

# The catalogue has to hold something, and every id has to be its own: an empty one reads
# as a green run of nothing, and a repeated id lets a selection skip the second entry.
if [ "${#IDS[@]}" -eq 0 ]; then
	echo "run-mutations.sh: the catalogue has no entries" >&2
	exit 2
fi
dups="$(printf '%s\n' "${IDS[@]}" | sort | uniq -d)"
if [ -n "$dups" ]; then
	echo "run-mutations.sh: the catalogue holds an id more than once: $dups" >&2
	exit 2
fi

if [ "$LIST" -eq 1 ]; then
	for id in "${IDS[@]}"; do printf '%s\n' "$id"; done
	exit 0
fi

SELECTED=()
if [ "${#ONLY[@]}" -eq 0 ]; then
	SELECTED=("${!IDS[@]}")
else
	for want in "${ONLY[@]}"; do
		found=0
		for i in "${!IDS[@]}"; do
			if [ "${IDS[$i]}" = "$want" ]; then
				SELECTED+=("$i")
				found=1
				break
			fi
		done
		if [ "$found" -eq 0 ]; then
			echo "run-mutations.sh: no mutation with the id $want" >&2
			exit 2
		fi
	done
fi

# --- the copies ------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

copy_repo() { # <destination>
	local dest="$1"
	mkdir -p "$dest" || return 1
	git -C "$REPO" archive HEAD | tar -x -C "$dest"
}

mutate() { # <file> <old> <new>
	python3 -I - "$1" "$2" "$3" <<-'PY'
		import pathlib
		import sys

		path, old, new = sys.argv[1:4]
		target = pathlib.Path(path)
		text = target.read_text(encoding="utf-8")
		count = text.count(old)
		if count != 1:
		    print(f"{path}: the text to replace appears {count} times", file=sys.stderr)
		    raise SystemExit(1)
		if old == new:
		    print(f"{path}: the mutation replaces the text with itself", file=sys.stderr)
		    raise SystemExit(1)
		mutated = text.replace(old, new)
		if mutated == text:
		    print(f"{path}: the mutation left the file unchanged", file=sys.stderr)
		    raise SystemExit(1)
		target.write_text(mutated, encoding="utf-8")
	PY
}

syntax_ok() { # <file> -> 0 when it parses, 1 when it does not, 2 when no check is known
	local rc=0
	case "$1" in
	*.py)
		PYTHONPYCACHEPREFIX="$WORK/pycache" python3 -m py_compile "$1" >/dev/null 2>&1 || rc=1
		;;
	*.yml | *.yaml)
		# A workflow is a control too: its suite list is what a pull request
		# can shorten, and the tests that read it parse it as YAML.
		python3 -I -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1" >/dev/null 2>&1 || rc=1
		;;
	*.sh | *.bash)
		bash -n "$1" >/dev/null 2>&1 || rc=1
		# A shell script of this repository carries python in a heredoc, and
		# `bash -n` cannot see it. A mutation that breaks the python would
		# leave a script that dies of a syntax error, which reads as a kill
		# of a guard that was never removed.
		[ "$rc" -eq 0 ] || return "$rc"
		python3 -I - "$1" <<-'PY' >/dev/null 2>&1 || rc=1
			import re
			import sys

			# Every heredoc this file hands to python3, and its body. Only
			# those: a heredoc that carries shell or text is not python and
			# compiling it would fail a file that is perfectly correct.
			pattern = re.compile(r"python3[^\n]*<<-?'([A-Za-z_][A-Za-z0-9_]*)'")
			lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
			bodies = []
			for index, line in enumerate(lines):
			    match = pattern.search(line)
			    if not match:
			        continue
			    tag = match.group(1)
			    body = []
			    for following in lines[index + 1:]:
			        if following.strip() == tag:
			            break
			        body.append(following)
			    else:
			        # An unterminated heredoc: the shell parser is the
			        # authority on that, not this.
			        body = None
			        break
			    if body is not None:
			        bodies.append("\n".join(body))
			for body in bodies:
			    compile(body, sys.argv[1], "exec")
		PY
		;;
	*)
		# A script without an extension is shell when its shebang says so.
		head -n 1 "$1" 2>/dev/null \
			| grep -qE '^#!.*(/| )(sh|bash|dash)([[:space:]]|$)' || return 2
		shell="$(head -n 1 "$1" 2>/dev/null)"
		case "$shell" in
		*bash*) bash -n "$1" >/dev/null 2>&1 || rc=1 ;;
		*) sh -n "$1" >/dev/null 2>&1 || rc=1 ;;
		esac
		;;
	esac
	return "$rc"
}

# A suite that fails in a pristine copy cannot tell a mutant from an unmutated
# tree, so it is excluded. Each suite is measured once, against a copy of its
# own that carries no mutation.
declare -A BASE
baseline_of() { # <test path> -> pass | fail | missing
	local test="$1" dest="$WORK/baseline"
	rm -rf "$dest"
	if ! copy_repo "$dest"; then
		echo "error"
		return
	fi
	if [ ! -f "$dest/$test" ]; then
		echo "missing"
		return
	fi
	if (cd "$dest" && bash "$test" >"$WORK/baseline.log" 2>&1); then
		echo "pass"
	else
		echo "fail"
	fi
}

is_excluded() { # <test path> -> 0 when it is on the always-excluded list
	local test="$1" name
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ "$name" = "$test" ] && return 0
	done <<<"$ALWAYS_EXCLUDED"
	return 1
}

for i in "${SELECTED[@]}"; do
	IFS=',' read -r -a wanted <<<"${TESTS[$i]}"
	for t in "${wanted[@]}"; do
		[ -n "$t" ] || continue
		if is_excluded "$t"; then
			echo "run-mutations.sh: $t is excluded, it needs the git metadata the copy does not have"
			continue
		fi
		[ -n "${BASE[$t]:-}" ] && continue
		BASE[$t]="$(baseline_of "$t")"
		case "${BASE[$t]}" in
		pass) ;;
		fail)
			echo "run-mutations.sh: $t fails without any mutation, it is excluded"
			;;
		missing)
			echo "run-mutations.sh: $t is not in the copy of the repository" >&2
			exit 2
			;;
		*)
			echo "run-mutations.sh: the copy of the repository failed" >&2
			exit 2
			;;
		esac
	done
done

# --- the sweep -------------------------------------------------------------------
survivors=0
errors=0
entries=0

run_entry() { # <index> -> 0 when a test killed it, 1 when it survived, 2 when it could not be run
	local idx="$1"
	local id="${IDS[$idx]}" file="${FILES[$idx]}" old="${OLDS[$idx]}" new="${NEWS[$idx]}"
	local dest="$WORK/mutant"
	local -a wanted
	local t killed=0 ran=0 rc=0
	IFS=',' read -r -a wanted <<<"${TESTS[$idx]}"

	rm -rf "$dest"
	if ! copy_repo "$dest"; then
		echo "mutation $id: the copy of the repository failed" >&2
		return 2
	fi
	if [ ! -f "$dest/$file" ]; then
		echo "mutation $id: $file is not in the copy of the repository" >&2
		return 2
	fi
	if ! mutate "$dest/$file" "$old" "$new"; then
		echo "mutation $id: the text to replace is not in $file exactly once, or the mutation left it unchanged" >&2
		return 2
	fi
	rc=0
	syntax_ok "$dest/$file" || rc=$?
	if [ "$rc" -ne 0 ]; then
		case "$rc" in
		2)
			echo "mutation $id: there is no syntax check for $file" >&2
			;;
		*)
			echo "mutation $id: the mutation leaves $file with a syntax error" >&2
			;;
		esac
		return 2
	fi
	for t in "${wanted[@]}"; do
		[ -n "$t" ] || continue
		if is_excluded "$t"; then
			echo "mutation $id: $t is excluded, it needs the git metadata the copy does not have"
			continue
		fi
		if [ "${BASE[$t]:-fail}" != "pass" ]; then
			echo "mutation $id: $t is excluded, it fails without any mutation"
			continue
		fi
		ran=$((ran + 1))
		if (cd "$dest" && bash "$t" >"$WORK/test.log" 2>&1); then
			echo "mutation $id: $t still passes"
		else
			echo "mutation $id: killed by $t"
			# The reason the suite went red, not only the colour: a suite that
			# fails for another reason is a kill that never happened.
			grep -m 5 -E '^[[:space:]]*FAIL' "$WORK/test.log" | sed 's/^/    /' || true
			killed=$((killed + 1))
		fi
	done
	if [ "$ran" -eq 0 ]; then
		echo "mutation $id: every test it names fails without any mutation, none of them can tell" >&2
		return 2
	fi
	if [ "$killed" -eq 0 ]; then
		echo "mutation $id: SURVIVED, none of the tests it names failed" >&2
		return 1
	fi
	return 0
}

for i in "${SELECTED[@]}"; do
	entries=$((entries + 1))
	rc=0
	run_entry "$i" || rc=$?
	case "$rc" in
	0) ;;
	1) survivors=$((survivors + 1)) ;;
	*) errors=$((errors + 1)) ;;
	esac
done

echo "$entries entries, $survivors survived, $errors could not be run"
[ "$survivors" -eq 0 ] && [ "$errors" -eq 0 ]
