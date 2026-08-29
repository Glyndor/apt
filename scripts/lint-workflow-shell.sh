#!/usr/bin/env bash
# Lint the shell embedded in `run:` blocks of .github/workflows/*.yml.
#
# The shellcheck job collects files by extension and by shebang, so it sees
# scripts/ and tests/ and never sees the several hundred lines of shell that
# live inside workflows. That shell is not less load-bearing for being
# embedded: it is the shell that signs, publishes and gates.
#
# Both forms are covered: a `run: |` block and a single-line `run: cmd`. The
# single-line form was skipped when this was written, and the check said so on
# every run rather than closing it; the seven such steps across the three
# channel repositories turned out to be plain invocations with nothing the
# linter could say about them, so this closes a hole that was cheap rather
# than urgent.
#
# A finding is reported against the workflow and the line the `run:` block
# starts on, not against the temporary file, so the error is navigable.
#
# `${{ ... }}` is not shell. It is replaced with a literal before linting, so
# the linter parses the block instead of reporting on GitHub's syntax. (That
# sentence starts with "the linter" rather than naming the tool, because a
# comment whose first word is the tool's name is read as a directive to it and
# fails to parse -- which this script's own lint caught.)
#
# The substitution is unquoted on purpose: an expression interpolated into an
# unquoted word really is subject to word splitting on the runner, and that is
# a finding worth keeping rather than hiding.
#
# Exits non-zero when the run: blocks contain no shell at all. A linter that
# inspected nothing prints the same success line as one that inspected
# everything and found nothing, which is the failure this script exists to
# close; it must not reproduce it.
set -euo pipefail

severity="${1:-style}"
root="$(cd "$(dirname "$0")/.." && pwd)"
workflows="$root/.github/workflows"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "::error::shellcheck is not on PATH; this check cannot run" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

blocks=0
failed=0

for wf in "$workflows"/*.yml "$workflows"/*.yaml; do
	[ -f "$wf" ] || continue
	name="$(basename "$wf")"

	# One file per `run: |` block, named for the line the block opens on.
	# The block ends at the first non-blank line indented no further than the
	# `run:` key itself, which is how YAML block scalars end.
	awk -v dir="$work" -v tag="$name" '
		function close_block() { if (out != "") { close(out); out = "" } }
		/^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ {
			close_block()
			key = match($0, /[^ ]/) - 1
			out = sprintf("%s/%s@%d.sh", dir, tag, NR)
			print "#!/usr/bin/env bash" > out
			body = -1
			next
		}
		out != "" {
			if ($0 ~ /^[[:space:]]*$/) { print "" > out; next }
			here = match($0, /[^ ]/) - 1
			if (here <= key) { close_block(); next }
			if (body < 0) body = here
			print substr($0, body + 1) > out
			next
		}
		# A single-line `run: cmd` is shell too, and skipping it was a hole
		# this check announced ("N single-line run: step(s) not linted")
		# rather than closed. Each becomes its own one-line block, so a
		# finding still lands on the right workflow line.
		/^[[:space:]]*run:[[:space:]]*[^|>[:space:]]/ {
			close_block()
			cmd = $0
			sub(/^[[:space:]]*run:[[:space:]]*/, "", cmd)
			# A YAML scalar may be quoted; the shell inside is the same.
			if (cmd ~ /^".*"$/ || cmd ~ /^'"'"'.*'"'"'$/) {
				cmd = substr(cmd, 2, length(cmd) - 2)
			}
			# NR-1, not NR. The reader adds (body line - 1) to the recorded
			# line, which is right for a block whose body starts on the line
			# after `run:`. Here the command IS the `run:` line, so the
			# recorded line has to be one earlier for the sum to land on it.
			one = sprintf("%s/%s@%d.sh", dir, tag, NR - 1)
			print "#!/usr/bin/env bash" > one
			print cmd > one
			close(one)
			next
		}
		END { close_block() }
	' "$wf"
done

for block in "$work"/*.sh; do
	[ -f "$block" ] || continue
	blocks=$((blocks + 1))

	base="$(basename "$block" .sh)"
	wf_name="${base%@*}"
	wf_line="${base##*@}"

	# The shebang counts as line 1 and the block body starts at line 2, so a
	# finding on line N of the block sits on line (start + N - 1) of the
	# workflow: start is the `run:` line and body line 1 follows it.
	sed 's/\${{[^}]*}}/GHEXPR/g' "$block" > "$block.clean"
	mv "$block.clean" "$block"

	if ! out="$(shellcheck -S "$severity" -f gcc "$block" 2>&1)"; then
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			n="$(printf '%s' "$line" | cut -d: -f2)"
			rest="$(printf '%s' "$line" | cut -d: -f4-)"
			case "$n" in
			'' | *[!0-9]*) echo "::error::$wf_name: $line" >&2 ;;
			*) echo "::error file=.github/workflows/$wf_name,line=$((wf_line + n - 1))::$rest" >&2 ;;
			esac
			failed=1
		done <<<"$out"
	fi
done

if [ "$blocks" -eq 0 ]; then
	echo "::error::found no \`run: |\` blocks under .github/workflows; the extractor is broken or the path is wrong" >&2
	exit 1
fi

if [ "$failed" -ne 0 ]; then
	echo "shellcheck (severity $severity) found problems in the shell embedded in workflows." >&2
	exit 1
fi

echo "$blocks embedded \`run:\` block(s) are clean at severity $severity."
