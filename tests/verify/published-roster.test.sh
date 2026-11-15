#!/usr/bin/env bash
#
# Tests for scripts/verify/published-roster.sh, the roster the health check asks
# installers for.
#
# A throwaway repository has two commits of publish.yml, the second adding a
# product. Which roster is printed says which tree it came from: the commit of the
# last successful publish when the API names one that can be fetched, and this
# checkout in every other case. A fake `gh` on PATH serves the SHA, so no case
# touches the network.
#
# Requires: bash, git.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/published-roster.sh"
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

git_in() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }

ORIGIN="$WORK/origin"
git init -q -b main "$ORIGIN"
mkdir -p "$ORIGIN/scripts/verify" "$ORIGIN/.github/workflows"
cp "$SCRIPT" "$ORIGIN/scripts/verify/published-roster.sh"
write_roster() { printf 'env:\n  PRODUCTS: "%s"\n' "$1" > "$ORIGIN/.github/workflows/publish.yml"; }
write_roster "alpha beta"
git_in "$ORIGIN" add -A; git_in "$ORIGIN" commit -qm one
OLD="$(git_in "$ORIGIN" rev-parse HEAD)"
write_roster "alpha beta gamma:all"
git_in "$ORIGIN" add -A; git_in "$ORIGIN" commit -qm two
NEW="$(git_in "$ORIGIN" rev-parse HEAD)"

CLONE="$WORK/clone"
git clone -q "file://$ORIGIN" "$CLONE"
chmod +x "$CLONE/scripts/verify/published-roster.sh"

mkdir -p "$WORK/bin"
fake_gh() { # <stdout> <exit>
	printf '#!/usr/bin/env bash\nprintf "%%s " "$@" >> "%s/gh.args"\nprintf "\\n" >> "%s/gh.args"\nprintf "%%s\\n" %q\nexit %s\n' "$WORK" "$WORK" "$1" "$2" > "$WORK/bin/gh"
	chmod +x "$WORK/bin/gh"
}

run() { # prints the roster on one line, or the exit status when it fails
	local out rc=0
	out="$(PATH="$WORK/bin:$PATH" bash "$CLONE/scripts/verify/published-roster.sh" 2>"$WORK/log")" || rc=$?
	if [ "$rc" -ne 0 ]; then echo "exit $rc"; else echo "$out" | tr '\n' ' ' | sed 's/ $//'; fi
}

fake_gh "$OLD" 0
check "the published commit, older than HEAD, gives the roster it was built for" "alpha beta" "$(run)"
check "and the log says which commit it used" "1" "$(grep -c "published commit ${OLD:0:7}" "$WORK/log")"
check "a product merged after that publish is not asked for" "0" "$(run | grep -c gamma)"

fake_gh "$NEW" 0
check "the lookup asks only for runs on main" "1" "$(grep -q -- '--branch main' "$WORK/gh.args" && echo 1 || echo 0)"
check "a published commit equal to HEAD uses this checkout, spec stripped to the name" "alpha beta gamma" "$(run)"

fake_gh "" 1
check "an API failure falls back to this checkout" "alpha beta gamma" "$(run)"

fake_gh "" 0
check "no successful publish run falls back to this checkout" "alpha beta gamma" "$(run)"

fake_gh "not-a-sha" 0
check "an answer that is not a commit id falls back" "alpha beta gamma" "$(run)"

fake_gh "0123456789abcdef0123456789abcdef01234567" 0
check "a commit that cannot be fetched falls back" "alpha beta gamma" "$(run)"
check "and says so" "1" "$(grep -c 'not usable' "$WORK/log")"

# A published commit that is fetched but whose workflow has no roster it can read: the
# checkout must not stand in for it, because its roster is the one to avoid.
write_roster_other() { printf 'env:\n  OTHER: "x"\n' > "$ORIGIN/.github/workflows/publish.yml"; }
write_roster_other
git_in "$ORIGIN" add -A; git_in "$ORIGIN" commit -qm three
UNREADABLE="$(git_in "$ORIGIN" rev-parse HEAD)"
fake_gh "$UNREADABLE" 0
check "a published commit with no readable roster stops the check, not the checkout's list" "exit 1" "$(run)"
check "and the error names the published commit" "1" "$(grep -c "published commit ${UNREADABLE:0:7} has no PRODUCTS list" "$WORK/log")"

# A name that is not a plain product name never reaches the installer paths.
write_roster "alpha;touch-x beta"
git_in "$ORIGIN" add -A; git_in "$ORIGIN" commit -qm four
HOSTILE="$(git_in "$ORIGIN" rev-parse HEAD)"
fake_gh "$HOSTILE" 0
check "a hostile published roster is refused" "exit 1" "$(run)"
check "and the error names the name" "1" "$(grep -c "not a plain product name" "$WORK/log")"

# The lookup asks for exactly what it needs: the real CLI would answer something else
# if a flag went missing, and the script would fall back without a word.
fake_gh "$OLD" 0
rm -f "$WORK/gh.args"
run >/dev/null
for flag in '--workflow publish.yml' '--branch main' '--status success' '--limit 1' '--json headSha'; do
	check "the lookup passes ${flag}" "1" "$(grep -c -- "$flag" "$WORK/gh.args")"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
