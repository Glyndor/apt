#!/usr/bin/env bash
# Every `gpgconf --kill` carries a `timeout`.
#
# These calls sit in EXIT traps and cleanup functions, ahead of the `rm -rf`
# that removes the working directory. gpgconf talks to the agent over a socket,
# and against an agent that accepts the connection and never answers it waits
# forever: measured on 2026-11-08, install-template-limits.test.sh printed
# "DONE ... 19 0" and then sat 12 minutes in `gpgconf --kill all`, so the trap
# never reached `rm -rf` and 27 working directories of 41 MiB were left in /tmp.
# In build-repo.sh and publish.yml the same hang would hold the publish job to
# its timeout. The kill is best effort (`|| true`), so a deadline costs nothing.
#
# A gpgconf kill is any line with `gpgconf` and `--kill`. It is bounded when
# `timeout <n>` stands directly before `gpgconf`, with an optional leading
# VAR=value assignment in front of the timeout. The scan covers scripts/,
# tests/ and .github/workflows/, and skips this file, which names the pattern.
#
# Requires: bash, grep.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SELF="${BASH_SOURCE[0]##*/}"
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

# Print "<file>:<line>" for each unbounded gpgconf kill under the given roots.
audit() { # <root>...
	local file
	while IFS= read -r file; do
		[ "${file##*/}" = "$SELF" ] && continue
		grep -nE 'gpgconf' "$file" | grep -- '--kill' | grep -vE '^[0-9]+:[[:space:]]*#' \
			| grep -vE 'timeout[[:space:]]+[0-9]+[[:space:]]+gpgconf' \
			| sed "s#^#${file#"$HERE"/}:#" | cut -d: -f1,2
	done < <(find "$@" -type f \( -name '*.sh' -o -name '*.yml' \) | sort)
}

mkdir -p "$WORK/planted"
cat > "$WORK/planted/loose.sh" <<'PLANT'
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$W"' EXIT
PLANT
cat > "$WORK/planted/bounded.sh" <<'PLANT'
trap 'timeout 10 gpgconf --kill all 2>/dev/null || true; rm -rf "$W"' EXIT
PLANT
cat > "$WORK/planted/assigned.sh" <<'PLANT'
GNUPGHOME="$h" timeout 10 gpgconf --kill all >/dev/null 2>&1 || true
PLANT
cat > "$WORK/planted/comment.sh" <<'PLANT'
# gpgconf --kill all is what the trap runs
PLANT

check "an unbounded kill is reported with its file" "1" "$(audit "$WORK/planted" | grep -c 'loose.sh')"
check "a bounded kill is not reported" "0" "$(audit "$WORK/planted" | grep -c 'bounded.sh')"
check "a bounded kill behind an assignment is not reported" "0" "$(audit "$WORK/planted" | grep -c 'assigned.sh')"
check "a comment naming the command is not reported" "0" "$(audit "$WORK/planted" | grep -c 'comment.sh')"

scanned="$(find "$HERE/scripts" "$HERE/tests" "$HERE/.github/workflows" -type f \( -name '*.sh' -o -name '*.yml' \) -print0 \
	| xargs -0 grep -l -- '--kill' | wc -l | tr -d ' ')"
check "the real tree has gpgconf kills to inspect" "1" "$([ "$scanned" -ge 5 ] && echo 1 || echo 0)"
check "no gpgconf kill in the real tree is unbounded" "" "$(audit "$HERE/scripts" "$HERE/tests" "$HERE/.github/workflows" | tr '\n' ' ')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "$SELF" "$pass" "$fail"
[ "$fail" -eq 0 ]
