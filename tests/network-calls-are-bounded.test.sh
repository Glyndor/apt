#!/usr/bin/env bash
# Every curl invocation under scripts/ carries a --max-time deadline.
#
# The drift scripts and the install-template.sh both hit the network. The
# scripts run on a runner or, in install-template.sh's case, on a user's
# machine: a connection that opens but never finishes its response can hold
# the runner or the user indefinitely. --max-time is the deadline that closes
# that hole, and the deadline that turns the wait into a FETCH FAILURE in the
# drift script's classification -- which is the property the script's own
# header argues for.
#
# The rule is strict and the cases are written against the real tree first,
# then against planted violations. Comment lines are not invocations: a
# curl mentioned in prose or in a string argument is not a curl that runs,
# and the scanner walks those past without counting them. A curl invocation
# is a line whose first non-whitespace token is the literal `curl`.
#
# A gate that inspected nothing prints the same success line as one that
# did, so the planted-violation case seeds a script with a missing deadline
# and the test names the file and the line that lost it.
#
# Requires: bash.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$HERE/scripts"

pass=0
fail=0

check() { # $1=description $2=expected $3=actual
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

# Walk every script. A line counts when its first non-whitespace token is
# `curl`; the dead simple heuristic is right for this repository because
# every other `curl` mention is either a comment or a string literal the
# shell never executes (`PACKAGE_ITEMS="...<code>curl ...</code>..."` and the
# `fail` argument in install-template.sh's `[ "$(id -u)" -eq 0 ] || fail
# "run this as root: curl ..."`). Those do not start with `curl`, so they
# fall out naturally.
#
# A curl invocation can span continuation lines (a `\` at the end of a line
# joins it to the next). The scanner stitches continuations together and
# inspects the joined text for `--max-time`, so a curl whose deadline sits
# on the next line is not falsely flagged.
#
# Returns: <file>:<line>:<trimmed-invocation>, one per violation (a curl
# invocation without --max-time). Empty when the tree is clean.
violations() {
	awk -v dir="$SCRIPTS" '
		function flush() {
			if (cmd == "") return
			if (cmd ~ /--max-time/) { cmd = ""; return }
			sub(/[[:space:]]+\\$/, "", cmd)
			printf "%s:%d:%s\n", file, startline, orig
			cmd = ""
		}
		FNR == 1 { file = FILENAME; sub(".*/", "", file); next }
		{
			t = $0
			sub(/^[[:space:]]+/, "", t)
			if (t == "") { flush(); next }
			if (t ~ /^#/) { flush(); next }
			if (cmd == "" && t !~ /^curl([[:space:]]|$)/) next
			if (cmd == "") { orig = $0; startline = FNR; cmd = t; next }
			cmd = cmd " " t
			if (t !~ /\\$/) flush()
		}
		END { flush() }
	' \
		"$SCRIPTS"/*.sh \
		2>/dev/null || true
}

says() { # $1=output  $2=pattern
	printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0
}

# --- the real tree passes --------------------------------------------------

list="$(violations)"
check "every real curl invocation under scripts/ carries --max-time" "" "$list"

# --- a planted curl without --max-time is caught and named -----------------
#
# The same scanner runs against a temporary tree that carries one curl
# invocation without a deadline. The test must name the file and the line.
# A scanner that returns nothing on this tree is the failure the planted
# case exists to close: it reads as "no violations found" on a tree that
# has one.

plant="$(mktemp -d)"
trap 'rm -rf "$plant"' EXIT
mkdir -p "$plant/scripts"

cat >"$plant/scripts/planted.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL "https://example.invalid/file"
SH

list="$(SCRIPTS="$plant/scripts" violations)"
check "a planted curl without --max-time is named" \
	"planted.sh:3:curl -fsSL \"https://example.invalid/file\"" "$list"

# --- a comment line is not an invocation ----------------------------------
#
# A `curl` token inside a comment is prose, not a shell command. The
# scanner must walk it past without flagging it. The first draft of this
# rule used to claim it ignored comments while actually only ignoring the
# leading `#`, which trips on indented comments; the case below pins the
# indented shape so a regression here turns red rather than going silent.

rm -f "$plant/scripts/planted.sh"
cat >"$plant/scripts/with-comments.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# this is the line shellcheck is meant to never see, with curl -fsSL in it
	# an indented comment with curl -fsSL "https://example.invalid/file"
curl -fsSL --max-time 30 "https://example.invalid/ok"
SH

list="$(SCRIPTS="$plant/scripts" violations)"
check "a curl mentioned only in a comment is not flagged" "0" \
	"$(says "$list" 'with-comments.sh')"
check "and the real invocation on the next line still passes" "" \
	"$(printf '%s\n' "$list" | sed -n '/with-comments.sh/p')"

# --- a curl mentioned inside a string is not an invocation ----------------
#
# The same shape covers the existing files: build-index-page.sh prints an
# HTML <code> snippet containing `curl` and install-template.sh passes
# `curl` as the argument of `fail`. Both are not invocations; both must
# not turn this test red.

rm -f "$plant/scripts/with-comments.sh"
cat >"$plant/scripts/with-strings.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PACKAGE_ITEMS="$PACKAGE_ITEMS<li><code>curl -fsSL https://example.invalid/install | sudo sh</code></li>"
[ "$(id -u)" -eq 0 ] || fail "run this as root: curl -fsSL https://example.invalid/install | sudo sh"
SH

list="$(SCRIPTS="$plant/scripts" violations)"
check "a curl mentioned only inside a string is not flagged" "0" \
	"$(says "$list" 'with-strings.sh')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
