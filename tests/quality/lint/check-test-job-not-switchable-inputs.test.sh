#!/usr/bin/env bash
# Behaviour tests for the part of scripts/quality/lint/check-test-job-not-switchable.sh
# that reads what a caller passes to a local reusable workflow.
#
# A reusable defines a required check, and some of its inputs weaken it:
# `tooling-isolation: false` skips the secret rule, `severity: ignore` makes the
# shell lint report nothing, `exclude-pattern: ".*"` leaves the line limit
# without a file to measure. A pull request that adds one to the `with:` of a
# caller leaves every suite green. The script holds a closed list of the inputs
# a caller may pass to each reusable and refuses the rest, naming the file, the
# job and the input; a reusable with no entry fails the rule; and the
# `extensions` of the line limit may grow but may not lose a word the callers of
# the base commit pass.
#
# Each case plants one caller in a temporary tree, runs the script as it ships
# and asserts which refusal came, and every refusal is paired with the same
# caller carrying only the inputs the list allows.
#
# Requires: python3 with PyYAML, and git.
# The fixtures carry literal `${{ ... }}` and backticks the assertions read;
# single quotes are the point.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/lint/check-test-job-not-switchable.sh"
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

said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

# The rule reads BASE_SHA when it is set; a case that is not about it must not
# inherit one from the environment it runs in.
run_in() { # $1=dir -> stdout+stderr, status in $?
	( cd "$1" && env -u BASE_SHA bash "$SCRIPT" 2>&1 )
}
run_base() { # $1=dir $2=BASE_SHA -> stdout+stderr, status in $?
	( cd "$1" && BASE_SHA="$2" bash "$SCRIPT" 2>&1 )
}

# A tree with a sound caller of reusable-shell-ci, so that the one defect in it
# is the one the case plants.
new() {
	rm -rf "$WORK/t"
	mkdir -p "$WORK/t/.github/workflows"
	cat > "$WORK/t/.github/workflows/tests.yml" <<'EOF'
name: Tests
on: pull_request
jobs:
  shell:
    uses: ./.github/workflows/reusable-shell-ci.yml
    with:
      test-command: >-
        ./tests/one.test.sh
EOF
	printf '%s' "$WORK/t"
}

# One caller of a local reusable. $5 is the lines of its `with:`, each written
# with its own indentation; empty writes no `with:` at all.
job_with() { # $1=dir $2=workflow file $3=job $4=reusable $5=with lines
	{
		printf 'name: Planted\non: pull_request\njobs:\n  %s:\n' "$3"
		printf '    uses: ./.github/workflows/%s\n' "$4"
		if [ -n "$5" ]; then printf '    with:\n%s' "$5"; fi
	} > "$1/.github/workflows/$2"
}

# --- every reusable: where its caller sits, and what its caller may pass ---------
declare -A FILE=(
	[reusable-dco.yml]=dco.yml
	[reusable-dependabot-freshness.yml]=freshness.yml
	[reusable-empty-diff.yml]=pr-hygiene.yml
	[reusable-line-limit.yml]=line-limit.yml
	[reusable-schedule-freshness.yml]=freshness.yml
	[reusable-shell-ci.yml]=extra.yml
	[reusable-workflow-lint.yml]=workflow-lint.yml
)
declare -A JOB=(
	[reusable-dco.yml]=dco
	[reusable-dependabot-freshness.yml]=dependabot-freshness
	[reusable-empty-diff.yml]=empty-diff
	[reusable-line-limit.yml]=line-limit
	[reusable-schedule-freshness.yml]=freshness-itself
	[reusable-shell-ci.yml]=shell-extra
	[reusable-workflow-lint.yml]=workflow-lint
)
# Everything the list allows, so the caller is the most a caller may pass.
declare -A ALLOWED=(
	[reusable-dco.yml]=''
	[reusable-dependabot-freshness.yml]=$'      max-age-days: 15\n'
	[reusable-empty-diff.yml]=''
	[reusable-line-limit.yml]=$'      extensions: "sh txt"\n'
	[reusable-schedule-freshness.yml]=$'      workflow: update.yml\n      max-age-days: 3\n      max-age-hours: 24\n      count-any-conclusion: true\n'
	[reusable-shell-ci.yml]=$'      test-command: ./tests/two.test.sh\n      apt-packages: shellcheck\n      skip-suite-paths: "docs/**"\n'
	[reusable-workflow-lint.yml]=''
)

for reusable in "${!FILE[@]}"; do
	d="$(new)"
	job_with "$d" "${FILE[$reusable]}" "${JOB[$reusable]}" "$reusable" "${ALLOWED[$reusable]}"
	out="$(run_in "$d")"; rc=$?
	check "$reusable: a caller passing only what the list allows is accepted" "0" "$rc"
done

# --- the inputs that weaken a check, one case each --------------------------------
while IFS='|' read -r reusable key value; do
	d="$(new)"
	job_with "$d" "${FILE[$reusable]}" "${JOB[$reusable]}" "$reusable" "${ALLOWED[$reusable]}      $key: $value"$'\n'
	out="$(run_in "$d")"; rc=$?
	check "$reusable: passing $key is refused" "1" "$rc"
	check "$reusable: $key: and the message names that file, job, input and reusable" "1" \
		"$(said "$out" "job \`${JOB[$reusable]}\` in .github/workflows/${FILE[$reusable]} passes the input \`$key\` to \`$reusable\`")"
	check "$reusable: $key: and says its callers may not pass it" "1" \
		"$(said "$out" 'which its callers may not pass')"
	check "$reusable: $key: and the sound shell caller is not blamed" "0" \
		"$(said "$out" 'in .github/workflows/tests.yml')"
done <<'LIST'
reusable-workflow-lint.yml|tooling-isolation|false
reusable-workflow-lint.yml|tooling-isolation|true
reusable-workflow-lint.yml|shellcheck-version|v0.1.0
reusable-shell-ci.yml|severity|ignore
reusable-shell-ci.yml|check-exec-bit|false
reusable-shell-ci.yml|working-directory|docs
reusable-shell-ci.yml|shellcheck-sha256|abc
reusable-line-limit.yml|hard-limit|100000
reusable-line-limit.yml|soft-limit|100000
reusable-line-limit.yml|exclude-pattern|".*"
reusable-dco.yml|unlisted-input|x
reusable-empty-diff.yml|unlisted-input|x
reusable-dependabot-freshness.yml|unlisted-input|x
reusable-schedule-freshness.yml|unlisted-input|x
LIST

# Two refused inputs on one caller are both named, not only the first.
d="$(new)"
job_with "$d" line-limit.yml line-limit reusable-line-limit.yml \
	$'      extensions: "sh txt"\n      hard-limit: 100000\n      exclude-pattern: ".*"\n'
out="$(run_in "$d")"; rc=$?
check "a caller with two refused inputs is refused" "1" "$rc"
check "and the first one is named" "1" "$(said "$out" 'the input `hard-limit`')"
check "and the second one is named" "1" "$(said "$out" 'the input `exclude-pattern`')"

# The list is closed in what it says as well: the message lists what is allowed.
d="$(new)"
job_with "$d" line-limit.yml line-limit reusable-line-limit.yml $'      hard-limit: 1\n'
out="$(run_in "$d")"; rc=$?
check "the refusal lists what the caller may pass" "1" "$(said "$out" 'they may pass: `extensions`')"

# --- a reusable the rule has not heard of -------------------------------------
d="$(new)"
job_with "$d" new.yml fresh reusable-new.yml ''
out="$(run_in "$d")"; rc=$?
check "a caller of a local reusable with no entry in the list is refused" "1" "$rc"
check "and the message names the job, the file and the reusable" "1" \
	"$(said "$out" 'job `fresh` in .github/workflows/new.yml calls `reusable-new.yml`')"
check "and says where to declare it" "1" "$(said "$out" 'no entry in ALLOWED_INPUTS')"

# --- the shape of `with:` ------------------------------------------------------
d="$(new)"
job_with "$d" dco.yml dco reusable-dco.yml ''
printf '    with:\n' >> "$d/.github/workflows/dco.yml"
out="$(run_in "$d")"; rc=$?
check "an empty with: on a caller that passes nothing is accepted" "0" "$rc"

d="$(new)"
job_with "$d" dco.yml dco reusable-dco.yml ''
printf '    with: nothing\n' >> "$d/.github/workflows/dco.yml"
out="$(run_in "$d")"; rc=$?
check "a with: that is not a mapping is refused" "1" "$rc"
check "and the message says it cannot be read" "1" "$(said "$out" 'is not a mapping')"

# --- the extensions of the line limit may grow, not shrink ---------------------
G="$WORK/g"
gitg() { git -C "$G" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
# A repository whose base commit carries the callers given as
# "file|job|extensions" lines on stdin, and whose working tree is that commit.
base_with() {
	local file job exts
	rm -rf "$G"
	mkdir -p "$G/.github/workflows"
	gitg init -q -b main
	new >/dev/null
	cp "$WORK/t/.github/workflows/tests.yml" "$G/.github/workflows/tests.yml"
	while IFS='|' read -r file job exts; do
		job_with "$G" "$file" "$job" reusable-line-limit.yml "      extensions: \"$exts\""$'\n'
	done
	gitg add -A
	gitg commit -qm base
	BASE="$(gitg rev-parse HEAD)"
}
# The pull request: the caller as it stands after the change.
pr_caller() { # $1=file $2=job $3=extensions (empty: no with:)
	local lines=''
	[ -z "$3" ] || lines="      extensions: \"$3\""$'\n'
	job_with "$G" "$1" "$2" reusable-line-limit.yml "$lines"
}
floor() { # $1=what $2=expected status $3=file $4=job $5=extensions
	pr_caller "$3" "$4" "$5"
	out="$(run_base "$G" "$BASE")"; rc=$?
	check "$1" "$2" "$rc"
}

base_with <<'LIST'
line-limit.yml|line-limit|sh yml txt
LIST
floor "extensions equal to the base's are accepted" 0 line-limit.yml line-limit "sh yml txt"
floor "the same extensions in another order are accepted" 0 line-limit.yml line-limit "txt sh yml"
floor "an extension added to the base's is accepted" 0 line-limit.yml line-limit "sh yml txt md"
floor "an extension taken from the base's is refused" 1 line-limit.yml line-limit "sh yml"
check "and the message names the extension taken" "1" "$(said "$out" 'without `txt`')"
check "and the job and the file" "1" \
	"$(said "$out" 'job `line-limit` in .github/workflows/line-limit.yml')"
floor "a caller that stops passing extensions is refused" 1 line-limit.yml line-limit ""
check "and every extension it dropped is named" "1" "$(said "$out" 'without `sh`, `txt`, `yml`')"
floor "an expression in place of the list is refused" 1 line-limit.yml line-limit '${{ vars.EXTENSIONS }}'
check "and it is refused for the extensions" "1" "$(said "$out" 'the input `extensions`')"
# The caller moves: the base's file is gone and the same job sits elsewhere.
rm -f "$G/.github/workflows/line-limit.yml"
floor "the list kept by a caller under another job and file is accepted" 0 renamed.yml other "sh yml txt"
floor "the list cut by a caller under another job and file is refused" 1 renamed.yml other "sh"
rm -f "$G/.github/workflows/renamed.yml"

# --- the list is one space between lowercase words, and nothing else --------------
#
# The reusable turns the list into a regular expression. A `|`, a `.*` or a
# bracket in it, and a new line, a tab or two spaces where the rule would see one
# separator, mean something else to the reusable than to the rule that compares
# the words, so the shape is refused whatever the base says. The YAML below is
# double quoted, so `\n` and `\t` reach the rule as a real new line and tab.
for bad in 'sh yml txt|.*' '.*' 'sh|yml txt' 'sh  yml txt' 'sh\nyml txt' 'sh\tyml txt' \
	'SH yml txt' ' sh yml txt' 'sh yml txt ' 'sh( yml txt' 'sh [yml] txt' 'sh. yml txt' 'sh*'; do
	floor "the list '$bad' is refused" 1 line-limit.yml line-limit "$bad"
	check "and it is refused for its shape, naming the job, the file and the input" "1" \
		"$(said "$out" 'job `line-limit` in .github/workflows/line-limit.yml passes the input `extensions` to `reusable-line-limit.yml` as something other than lowercase words')"
	check "and not for the words it lacks" "0" "$(said "$out" 'without `')"
done
floor "the list of the base, one space between lowercase words, is accepted" 0 line-limit.yml line-limit "sh yml txt"
floor "words with digits are accepted" 0 line-limit.yml line-limit "sh yml txt mp4 7z"
job_with "$G" line-limit.yml line-limit reusable-line-limit.yml $'      extensions: 5\n'
out="$(run_base "$G" "$BASE")"; rc=$?
check "a list that YAML reads as a number is refused" "1" "$rc"
check "and for its shape" "1" "$(said "$out" 'as something other than lowercase words')"
pr_caller line-limit.yml line-limit "sh|.*"
out="$(run_in "$G")"; rc=$?
check "a list with a | is refused with no base commit named too" "1" "$rc"
check "and for its shape" "1" "$(said "$out" 'as something other than lowercase words')"
pr_caller line-limit.yml line-limit "sh yml"
out="$(run_in "$G")"; rc=$?
check "a well-formed list is accepted with no base commit named" "0" "$rc"

pr_caller line-limit.yml line-limit "sh"
out="$(run_in "$G")"; rc=$?
check "with no base commit named the floor is not applied" "0" "$rc"

out="$(run_base "$G" "not-a-commit")"; rc=$?
check "a base that is not a commit id stops the rule" "1" "$rc"
check "and the message says so" "1" "$(said "$out" 'is not a commit id')"
out="$(run_base "$G" "0123456789abcdef0123456789abcdef01234567")"; rc=$?
check "a base commit that cannot be read stops the rule" "1" "$rc"
check "and the message says it cannot be read" "1" "$(said "$out" 'cannot be read')"

# Callers of the base in several files add up: the floor is every word any of
# them passes, not the words of one.
base_with <<'LIST'
line-limit.yml|line-limit|sh txt
second.yml|second|yml
LIST
rm -f "$G/.github/workflows/second.yml"
floor "the words of two base callers together are accepted" 0 line-limit.yml line-limit "sh txt yml"
floor "the words of only one of the two base callers are refused" 1 line-limit.yml line-limit "sh txt"
check "and the one it left out is named" "1" "$(said "$out" 'without `yml`')"
floor "the words of only the other base caller are refused" 1 line-limit.yml line-limit "yml"
check "and the words of the first one are the ones named" "1" "$(said "$out" 'without `sh`, `txt`')"

# A base without a caller of the line limit has no words to keep.
base_with </dev/null
floor "a base with no caller of the line limit asks for no extension" 0 line-limit.yml line-limit "sh"

# The base is read at its own file names and at its own kind of file: a caller
# in a .yaml file counts, and a reusable's own file is not a caller.
base_with <<'LIST'
line-limit.yaml|line-limit|sh md
LIST
rm -f "$G/.github/workflows/line-limit.yaml"
floor "a base caller in a .yaml file is held too" 1 line-limit.yml line-limit "sh"
check "and the word it left out is named" "1" "$(said "$out" 'without `md`')"
# Only the callers of the line limit count: another reusable's `extensions` is
# not a word the line limit measures.
base_with <<'LIST'
line-limit.yml|line-limit|sh
LIST
job_with "$G" other.yml other reusable-dco.yml $'      extensions: "zzz"\n'
gitg add -A
gitg commit -qm 'another reusable'
BASE="$(gitg rev-parse HEAD)"
rm -f "$G/.github/workflows/other.yml"
floor "the words another reusable's caller passes are not asked of the line limit" 0 line-limit.yml line-limit "sh"

base_with <<'LIST'
reusable-wrapper.yml|wrap|sh zzz
LIST
rm -f "$G/.github/workflows/reusable-wrapper.yml"
floor "a base file of a reusable asks for no extension of a caller" 0 line-limit.yml line-limit "sh"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
