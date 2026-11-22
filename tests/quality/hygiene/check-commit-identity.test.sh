#!/usr/bin/env bash
#
# Tests for scripts/quality/hygiene/check-commit-identity.sh: only GitHub noreply addresses
# pass, in the author, the Signed-off-by and the Co-authored-by, and the address of
# a rejected commit is never printed.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/hygiene/check-commit-identity.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

personal="someone@mail.example"
noreply="12345+someone@users.noreply.github.com"

repo="$WORK/repo"
git init -q "$repo"
commit() { # <author email> <message>
	git -C "$repo" -c user.name=t -c "user.email=$1" -c commit.gpgSign=false \
		commit -q --allow-empty -m "$2"
}
commit "$noreply" "base"
base="$(git -C "$repo" rev-parse HEAD)"

run() { (cd "$repo" && "$SCRIPT" "$base" HEAD 2>&1); }

commit "$noreply" "$(printf 'ok\n\nSigned-off-by: t <%s>' "$noreply")"
run >/dev/null; check "noreply author and sign-off pass" 0 "$?"

commit "49699333+dependabot[bot]@users.noreply.github.com" "bot"
run >/dev/null; check "a bot noreply address passes" 0 "$?"

commit "noreply@github.com" "web"
run >/dev/null; check "GitHub's own noreply passes" 0 "$?"

commit "$personal" "personal author"
out="$(run)"; rc=$?
check "a personal author address fails" 1 "$rc"
check "and the address is not printed" 0 "$(printf '%s' "$out" | grep -c "$personal")"
check "and the message names the author field" 1 "$(printf '%s' "$out" | grep -c 'the author address')"

git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nSigned-off-by: t <%s>' "$personal")"
out="$(run)"; rc=$?
check "a personal Signed-off-by fails" 1 "$rc"
check "and the address is not printed" 0 "$(printf '%s' "$out" | grep -c "$personal")"
check "and the message names the trailer" 1 "$(printf '%s' "$out" | grep -c 'a Signed-off-by address')"

git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nCo-authored-by: t <%s>' "$personal")"
run >/dev/null; check "a personal Co-authored-by fails" 1 "$?"

git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nSigned-off-by: t <%s> <%s>' "$personal" "$noreply")"
out="$(run)"; rc=$?
check "a personal address in front of a noreply one fails" 1 "$rc"
check "and the address is not printed" 0 "$(printf '%s' "$out" | grep -c "$personal")"

git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nSigned-off-by: just a name')"
out="$(run)"; rc=$?
check "a trailer with no address fails" 1 "$rc"
check "and says so" 1 "$(printf '%s' "$out" | grep -c 'with no address')"

git -C "$repo" reset -q --hard "$base"
commit "support@github.com" "older dependabot"
run >/dev/null; check "support@github.com passes" 0 "$?"

git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nSigned-off-by: t <%s>' "$noreply")"
commit "$personal" "second, personal"
run >/dev/null; check "one bad commit among good ones fails" 1 "$?"

# git reads the last paragraph of a message as its trailers. A line of either kind in
# another paragraph is in the history all the same.
git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nSigned-off-by: t <%s>\n\nthe body goes on\n\nfixes it' "$personal")"
out="$(run)"; rc=$?
check "a personal Signed-off-by outside the last paragraph fails" 1 "$rc"
check "and the message names the trailer" 1 "$(printf '%s' "$out" | grep -c 'a Signed-off-by address')"
check "and the address is not printed" 0 "$(printf '%s' "$out" | grep -c "$personal")"
git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nCo-authored-by: t <%s>\n\nthe body goes on\n\nfixes it' "$personal")"
run >/dev/null; check "a personal Co-authored-by outside the last paragraph fails" 1 "$?"
git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nsigned-off-by: t <%s>\n\nfixes it' "$personal")"
run >/dev/null; check "a trailer written in lower case fails" 1 "$?"
git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nSigned-off-by: t <%s>\n\nthe body goes on\n\nfixes it' "$noreply")"
out="$(run)"; rc=$?
check "the same message with noreply addresses is accepted" 0 "$rc"
git -C "$repo" reset -q --hard "$base"
commit "$noreply" "$(printf 'x\n\nthe address someone@mail.example is in the text, not in a trailer\n\nfixes it')"
run >/dev/null; check "an address in the text of the message is not a trailer" 0 "$?"

# A merge in the range is read like any other commit. The one GitHub writes is made by its
# own address and passes; one made by hand carries the identity of whoever made it.
merge() { # <author email> <committer email> <message>: merge a side branch into the base
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" checkout -q -b side
	commit "$noreply" "side"
	git -C "$repo" checkout -q -
	GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="$1" GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL="$2" \
		git -C "$repo" -c commit.gpgSign=false merge -q --no-ff -m "$3" side
	git -C "$repo" branch -q -D side
}
merge "$noreply" "noreply@github.com" "Merge branch main into the branch"
out="$(run)"; rc=$?
check "a merge by a noreply author committed by GitHub passes" 0 "$rc"
merge "$personal" "noreply@github.com" "Merge branch main into the branch"
out="$(run)"; rc=$?
check "a merge with a personal author fails" 1 "$rc"
check "and the message names the author" 1 "$(printf '%s' "$out" | grep -c 'the author address')"
merge "$noreply" "$personal" "Merge branch main into the branch"
out="$(run)"; rc=$?
check "a merge with a personal committer fails" 1 "$rc"
check "and the message names the committer of a merge" 1 "$(printf '%s' "$out" | grep -c 'the committer address of a merge')"
check "and the address is not printed" 0 "$(printf '%s' "$out" | grep -c "$personal")"
merge "$noreply" "noreply@github.com" "$(printf 'Merge\n\nSigned-off-by: t <%s>\n\nbody' "$personal")"
out="$(run)"; rc=$?
check "a merge with a personal sign-off fails" 1 "$rc"
check "and the message names the trailer" 1 "$(printf '%s' "$out" | grep -c 'a Signed-off-by address')"
git -C "$repo" reset -q --hard "$base"

# A range git cannot list is a failure, not a range with no commits to refuse. An
# empty range, which git can list, is accepted.
git -C "$repo" reset -q --hard "$base"
commit "$personal" "personal author"
out="$(cd "$repo" && "$SCRIPT" 0000000000000000000000000000000000000000 HEAD 2>&1)"; rc=$?
check "a base that does not exist fails" 1 "$rc"
check "and says the commits could not be listed" 1 "$(printf '%s' "$out" | grep -c 'could not list the commits')"
check "and does not say every commit is fine" 0 "$(printf '%s' "$out" | grep -c 'every commit uses')"
head_now="$(git -C "$repo" rev-parse HEAD)"
out="$(cd "$repo" && "$SCRIPT" "$head_now" HEAD 2>&1)"; rc=$?
check "a range with no commits is accepted" 0 "$rc"
check "and says every commit is fine" 1 "$(printf '%s' "$out" | grep -c 'every commit uses')"

"$SCRIPT" >/dev/null 2>&1; check "no arguments fails" 1 "$?"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
