#!/usr/bin/env bash
#
# The two jobs of commit-hygiene.yml check out the head of a pull request, so the scripts
# in that checkout are the pull request's own. A change that rewrote a script to exit 0
# would be judged by itself. Each step therefore takes its rule from the base commit and
# runs that, and this runs the real step, the text of the workflow and nothing else, in a
# repository whose head swaps both scripts for ones that always pass and carries a
# .gitattributes that hides what a file adds. The change under review is refused by the
# base's rule, for the reason that rule gives; the same change without the offence is
# accepted, so a step that refuses everything would not pass.
#
# Requires: python3 with yaml, git.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/commit-hygiene.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

step() { # <name of the step>: its run block
	python3 -I - "$WORKFLOW" "$1" <<'PY'
import sys
import yaml

steps = [s for job in yaml.safe_load(open(sys.argv[1]))["jobs"].values() for s in job["steps"]]
print(next(s["run"] for s in steps if s.get("name") == sys.argv[2]))
PY
}
IDENTITY="$(step "Every commit uses a GitHub noreply address")"
SCAN="$(step "The change adds no credential-shaped line")"

noreply="12345+someone@users.noreply.github.com"
repo="$WORK/repo"
mkdir -p "$WORK/tmp"
git init -q "$repo"
gitc() { git -C "$repo" -c user.name=t -c "user.email=${AUTHOR:-$noreply}" -c commit.gpgSign=false "$@"; }

mkdir -p "$repo/scripts/quality/hygiene"
for name in check-secrets.sh check-commit-identity.sh; do
	cp "$HERE/scripts/quality/hygiene/$name" "$repo/scripts/quality/hygiene/$name"
done
echo base > "$repo/README"; gitc add -A; gitc commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# head <author> <file> <content>: a change that swaps both scripts for ones that always pass,
# hides what files add, and adds one file.
head_commit() {
	git -C "$repo" reset -q --hard "$base"
	for name in check-secrets.sh check-commit-identity.sh; do
		printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/quality/hygiene/$name"
	done
	printf '* -diff\n' > "$repo/.gitattributes"
	printf '%s\n' "$3" > "$repo/$2"
	gitc add -A; AUTHOR="$1" gitc commit -q -m change
	head="$(git -C "$repo" rev-parse HEAD)"
}
run_step() { # <run block>: the status in $rc, the output in $out
	rc=0
	out="$(cd "$repo" && RUNNER_TEMP="$WORK/tmp" BASE="$base" HEAD="$head" bash -c "$1" 2>&1)" || rc=$?
}
said() { printf '%s\n' "$out" | grep -cF -- "$1" || true; }

aws="id AKI""A$(printf 'Q%.0s' {1..16})"
personal="someone@mail.example"

head_commit "$noreply" leak.txt "$aws"
run_step "$SCAN"
check "a credential is refused although the head swapped the script for one that passes" 1 "$rc"
check "and it is the base's rule that names it" 1 "$(said 'leak.txt:1 AWS access key')"
head_commit "$noreply" leak.txt "just a line"
run_step "$SCAN"
check "the same change without the credential is accepted" 0 "$rc"
check "and says nothing credential-shaped was added" 1 "$(said 'no credential-shaped lines added')"

head_commit "$personal" notes.txt "just a line"
run_step "$IDENTITY"
check "a personal address is refused although the head swapped the script for one that passes" 1 "$rc"
check "and it is the base's rule that names the author" 1 "$(said 'the author address')"
head_commit "$noreply" notes.txt "just a line"
run_step "$IDENTITY"
check "the same change with a noreply address is accepted" 0 "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
