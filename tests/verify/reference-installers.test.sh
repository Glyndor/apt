#!/usr/bin/env bash
#
# Tests for scripts/verify/reference-installers.sh, the reference the health
# check compares the served installers with.
#
# The generator is replaced by a stub that writes its own version into the
# installer, in a throwaway repository with two commits. Which version ends up in
# the output says which tree rendered it: the commit of the last successful
# publish when the API names one that can be fetched, and this checkout in every
# other case. A fake `gh` on PATH serves the SHA, so no case touches the network.
#
# Requires: bash, git.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/reference-installers.sh"
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

# origin holds both commits; the clone is where the script runs, at the second.
ORIGIN="$WORK/origin"
git init -q -b main "$ORIGIN"
mkdir -p "$ORIGIN/scripts/build" "$ORIGIN/scripts/verify"
cp "$SCRIPT" "$ORIGIN/scripts/verify/reference-installers.sh"
write_stub() { # <version>
	cat > "$ORIGIN/scripts/build/build-installers.sh" <<STUB
#!/usr/bin/env bash
out="\$1"; shift
mkdir -p "\$out"
for p in "\$@"; do echo "version $1" > "\$out/\$p"; done
STUB
	chmod +x "$ORIGIN/scripts/build/build-installers.sh"
}
write_stub 1
git_in "$ORIGIN" add -A; git_in "$ORIGIN" commit -qm one
OLD="$(git_in "$ORIGIN" rev-parse HEAD)"
write_stub 2
git_in "$ORIGIN" add -A; git_in "$ORIGIN" commit -qm two
NEW="$(git_in "$ORIGIN" rev-parse HEAD)"

CLONE="$WORK/clone"
git clone -q "file://$ORIGIN" "$CLONE"
chmod +x "$CLONE/scripts/build/build-installers.sh" "$CLONE/scripts/verify/reference-installers.sh"

mkdir -p "$WORK/bin"
fake_gh() { # <stdout> <exit>
	printf '#!/usr/bin/env bash\nprintf "%%s " "$@" >> "%s/gh.args"\nprintf "\\n" >> "%s/gh.args"\nprintf "%%s\\n" %q\nexit %s\n' "$WORK" "$WORK" "$1" "$2" > "$WORK/bin/gh"
	chmod +x "$WORK/bin/gh"
}

run() { # prints the version the installer for "podup" carries
	local out="$WORK/out"
	rm -rf "$out"
	PATH="$WORK/bin:$PATH" bash "$CLONE/scripts/verify/reference-installers.sh" "$out" podup >"$WORK/log" 2>&1
	cat "$out/podup" 2>/dev/null || echo "none"
}

fake_gh "$OLD" 0
check "the published commit, older than HEAD, renders the reference" "version 1" "$(run)"
check "and the log says which commit it used" "1" "$(grep -c "published commit ${OLD:0:7}" "$WORK/log")"

fake_gh "$NEW" 0
check "the lookup asks only for runs on main" "1" "$(grep -q -- '--branch main' "$WORK/gh.args" && echo 1 || echo 0)"
check "a published commit equal to HEAD uses this checkout" "version 2" "$(run)"

fake_gh "" 1
check "an API failure falls back to this checkout" "version 2" "$(run)"

fake_gh "" 0
check "no successful publish run falls back to this checkout" "version 2" "$(run)"

fake_gh "not-a-sha" 0
check "an answer that is not a commit id falls back" "version 2" "$(run)"

fake_gh "0123456789abcdef0123456789abcdef01234567" 0
check "a commit that cannot be fetched falls back" "version 2" "$(run)"
check "and says so" "1" "$(grep -c 'not usable' "$WORK/log")"

# A copy of the scripts outside any git checkout, as the workflow-step suite makes.
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT/scripts"
cp -r "$CLONE/scripts/." "$NOGIT/scripts/"
fake_gh "$OLD" 0
rm -rf "$WORK/out"
PATH="$WORK/bin:$PATH" bash "$NOGIT/scripts/verify/reference-installers.sh" "$WORK/out" podup >/dev/null 2>&1
check "outside a git checkout it renders from the copy it is in" "version 2" "$(cat "$WORK/out/podup" 2>/dev/null || echo none)"

check "the fetched worktree is removed afterwards" "0" \
	"$(git -C "$CLONE" worktree list | grep -c 'src')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
