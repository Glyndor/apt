#!/usr/bin/env bash
# Behaviour tests for .github/workflows/reusable-workflow-lint.yml itself: that
# each assertion it adds on top of actionlint is wired to the script that holds
# the rule, under the condition it is meant to run under.
#
# The rules live in scripts/quality/ and their cases in tests/quality/: one
# suite per script. What those suites cannot see is the workflow: a step that
# stops calling its script, or calls it under a condition that never holds,
# leaves every case of the script green and the gate gone. So each step is read
# out of the workflow as it ships and its `run:` is executed in a temporary tree
# that carries the real scripts, once over a planted violation, which must turn
# it red for that rule, and once over a clean tree, which must leave it green.
#
# Requires: python3 with PyYAML.
# The fixtures carry literal `${{ secrets.X }}`; single quotes are the point.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/reusable-workflow-lint.yml"
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

# One field of one step of the workflow-lint job, read with a YAML parser so
# a comment that names the script does not count as calling it.
field() { # $1=step name $2=run|if
	python3 -I - "$WORKFLOW" "$1" "$2" <<'PY'
import sys
import yaml
spec = yaml.safe_load(open(sys.argv[1]))
steps = spec["jobs"]["workflow-lint"]["steps"]
step = next((s for s in steps if s.get("name") == sys.argv[2]), None)
print("MISSING" if step is None else str(step.get(sys.argv[3], "")).strip())
PY
}

default_of() { # $1=input name
	python3 -I - "$WORKFLOW" "$1" <<'PY'
import sys
import yaml
spec = yaml.safe_load(open(sys.argv[1]))
# PyYAML reads the bare key `on` as the boolean True.
print(spec[True]["workflow_call"]["inputs"][sys.argv[2]].get("default"))
PY
}

said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

# A repository shaped like a caller, built as a pull request is checked out: a
# base commit, a branch on top and a --no-ff merge of it, so HEAD^1 is the base.
# The base carries a caller that runs a suite and a job that holds no secret,
# and the real rule scripts unless it is a first adoption.
RULES=(check-test-job-not-switchable.sh check-tooling-isolation.sh)
gitt() { git -C "$WORK/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
base_repo() { # $1=with|without the rule scripts in the base
	local x
	rm -rf "$WORK/t"
	mkdir -p "$WORK/t/.github/workflows" "$WORK/t/scripts/quality"
	gitt init -q -b main
	# The picker also takes the checker of the suites; it is not under test here.
	cp "$HERE/scripts/quality/check-suites-wired.sh" "$WORK/t/scripts/quality/"
	if [ "$1" = with ]; then
		for x in "${RULES[@]}"; do cp "$HERE/scripts/quality/$x" "$WORK/t/scripts/quality/"; done
	fi
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
	cat > "$WORK/t/.github/workflows/job.yml" <<'EOF'
name: Job
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      TOKEN: ${{ vars.PLAIN }}
    steps:
      - run: cargo install --locked cargo-cyclonedx
EOF
	gitt add -A
	gitt commit -qm base
	gitt checkout -q -b pr
}
merge_pr() {
	gitt add -A
	gitt commit -qm pr --allow-empty
	gitt checkout -q main
	gitt merge -q --no-ff pr -m merge
}
# The violation each rule exists to refuse, planted in the pull request.
violate() { # $1=rule
	case "$1" in
	check-test-job-not-switchable.sh)
		sed -i 's/^  shell:$/  shell:\n    if: false/' "$WORK/t/.github/workflows/tests.yml" ;;
	check-tooling-isolation.sh)
		sed -i 's/vars.PLAIN/secrets.DEPLOY_TOKEN/' "$WORK/t/.github/workflows/job.yml" ;;
	esac
}
refusal() { # $1=rule -> a fragment of that rule's refusal
	case "$1" in
	check-test-job-not-switchable.sh) printf '%s' 'job-level `if:`' ;;
	check-tooling-isolation.sh) printf '%s' 'installs third-party tooling while holding a secret' ;;
	esac
}
hollow() { # $1=rule: the pull request replaces the rule with one that passes
	printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/t/scripts/quality/$1"
}

PICK="$(field "Take the rule scripts from the base commit" run)"
pick() { # $1=event [$2=base sha the event names, default the merge's first parent]
	rm -rf "$WORK/rt"
	mkdir -p "$WORK/rt"
	local base
	base="${2-$(gitt rev-parse HEAD^1)}"
	out="$(cd "$WORK/t" && EVENT="$1" BASE_SHA="$base" RUNNER_TEMP="$WORK/rt" bash -e -o pipefail -c "$PICK" 2>&1)"
	rc=$?
}
rule() { # $1=run line -> output, status in rc
	out="$(cd "$WORK/t" && RUNNER_TEMP="$WORK/rt" bash -e -o pipefail -c "$1" 2>&1)"
	rc=$?
}

check "the rule scripts are taken on every event, before anything uses them" \
	"" "$(field "Take the rule scripts from the base commit" if)"

declare -A STEP=(
	[check-test-job-not-switchable.sh]="A required test job must not be switchable off"
	[check-tooling-isolation.sh]="A job holding a secret must not install third-party tooling"
)
declare -A CONDITION=(
	[check-test-job-not-switchable.sh]="steps.scope.outputs.needed != 'false'"
	[check-tooling-isolation.sh]='${{ inputs.tooling-isolation && steps.scope.outputs.needed != '"'false'"' }}'
)
for r in "${RULES[@]}"; do
	name="${r%.sh}"
	run="$(field "${STEP[$r]}" run)"
	check "$name: the step runs the copy the picker took, with an explicit interpreter" \
		"bash \"\$RUNNER_TEMP/lint-rules/$r\"" "$run"
	check "$name: and runs under its condition" "${CONDITION[$r]}" "$(field "${STEP[$r]}" if)"

	base_repo with; merge_pr
	pick pull_request; rule "$run"
	check "$name: a clean pull request passes through the step" "0" "$rc"

	base_repo with; violate "$r"; merge_pr
	pick pull_request; rule "$run"
	check "$name: a planted violation turns the step red" "1" "$rc"
	check "$name: and for that rule" "1" "$(said "$out" "$(refusal "$r")")"

	# The pull request hollows the rule out and breaks it in the same change.
	base_repo with; violate "$r"; hollow "$r"; merge_pr
	pick pull_request
	check "$name: on a pull request the picker says it read the base" "1" \
		"$(said "$out" "$r read from the base commit")"
	rule "$run"
	check "$name: a pull request that hollows the rule is still judged by the base's" "1" "$rc"
	check "$name: and refused for that rule" "1" "$(said "$out" "$(refusal "$r")")"
	# On a push there is no base to trust: the checkout is what landed.
	pick push; rule "$run"
	check "$name: on a push the checkout's copy decides" "0" "$rc"

	# First adoption: the base has no rule, so the checkout's copy decides.
	base_repo without
	for x in "${RULES[@]}"; do cp "$HERE/scripts/quality/$x" "$WORK/t/scripts/quality/"; done
	violate "$r"; merge_pr
	pick pull_request
	check "$name: a base without the rule falls back to the checkout" "0" "$(said "$out" "$r read from the base commit")"
	rule "$run"
	check "$name: and the checkout's rule refuses the violation" "1" "$rc"
done

base_repo without; merge_pr
pick pull_request
check "a rule in neither the base nor the checkout fails the picker" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# The base is the commit the event names, not HEAD^1 of the checkout. A pull
# request of two commits checked out at its own head has its first commit as
# HEAD^1, and that commit hollows the tooling rule out.
base_repo with; base="$(gitt rev-parse HEAD)"
hollow check-tooling-isolation.sh; gitt add -A; gitt commit -qm 'hollow the rule'
violate check-tooling-isolation.sh; gitt add -A; gitt commit -qm 'break it'
TOOLING_RUN="$(field "${STEP[check-tooling-isolation.sh]}" run)"
pick pull_request "$base"
check "with HEAD^1 inside the pull request, the picker reads the base the event names" "1" \
	"$(said "$out" "check-tooling-isolation.sh read from the base commit $base")"
rule "$TOOLING_RUN"
check "and that base's rule refuses the violation" "1" "$rc"
pick pull_request "$(gitt rev-parse HEAD^1)"
rule "$TOOLING_RUN"
check "control: had HEAD^1 been taken as the base, the hollowed rule would pass" "0" "$rc"

# A base the checkout lacks is fetched from origin; one that cannot be fetched,
# or no base at all on a pull request, fails rather than falling back.
base_repo with; base="$(gitt rev-parse HEAD)"; merge_pr
git clone -q --bare "$WORK/t" "$WORK/origin.git"
git -C "$WORK/origin.git" config uploadpack.allowAnySHA1InWant true
rm -rf "$WORK/t2"; git clone -q --depth 1 --branch main "file://$WORK/origin.git" "$WORK/t2"
check "the shallow checkout lacks the base commit" "1" \
	"$(git -C "$WORK/t2" cat-file -e "$base^{commit}" 2>/dev/null && echo 0 || echo 1)"
mv "$WORK/t" "$WORK/t.full"; mv "$WORK/t2" "$WORK/t"
pick pull_request "$base"
check "a base the checkout lacks is fetched and read" "1" \
	"$(said "$out" "check-tooling-isolation.sh read from the base commit $base")"
pick pull_request "$(printf '%040d' 7)"
check "a base that cannot be fetched fails the picker" "1" "$rc"
check "and says so rather than using the checkout" "1" "$(said "$out" 'Could not fetch the base commit')"
pick pull_request ""
check "a pull request event that names no base fails the picker" "1" "$rc"
rm -rf "$WORK/t" "$WORK/origin.git"; mv "$WORK/t.full" "$WORK/t"
check "and tooling-isolation is on unless a caller turns it off" "True" "$(default_of tooling-isolation)"

# ===========================================================================
# actionlint is the release binary, verified before it is extracted
# ===========================================================================

# Read from the job, not grepped from the file, so a comment naming a step or a
# value does not count.
job_facts="$(python3 -I - "$WORKFLOW" <<'PY'
import re
import sys
import yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["workflow-lint"]
env = job.get("env", {})
uses = [s.get("uses", "").split("@")[0] for s in job["steps"] if s.get("uses")]
runs = "\n".join(str(s.get("run", "")) for s in job["steps"])
print(bool(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", str(env.get("ACTIONLINT_VERSION", "")))),
      bool(re.fullmatch(r"[0-9a-f]{64}", str(env.get("ACTIONLINT_SHA256", "")))),
      "actions/setup-go" in uses, "actions/cache" in uses,
      bool(re.search(r"(?m)^\s*go\s+install\b", runs)))
PY
)"
check "the job pins an exact actionlint version and the sha256 of its tarball, and needs no Go" \
	"True True False False False" "$job_facts"

install="$(field "Install actionlint" run)"
mkdir -p "$WORK/release/pkg" "$WORK/bin"
printf '#!/bin/sh\necho fixture actionlint\n' > "$WORK/release/pkg/actionlint"
chmod +x "$WORK/release/pkg/actionlint"
tar -czf "$WORK/release/actionlint.tar.gz" -C "$WORK/release/pkg" actionlint
good_sha="$(sha256sum "$WORK/release/actionlint.tar.gz" | cut -d' ' -f1)"
# curl serves the fixture tarball and records the URL it was asked for.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	-*) shift ;;
	*) printf '%s\n' "$1" >> "$CURL_LOG"; shift ;;
	esac
done
cp "$FIXTURE_TARBALL" "$out"
EOF
chmod +x "$WORK/bin/curl"
install_with() { # $1=sha256 -> status in rc
	rm -rf "$WORK/rt"; mkdir -p "$WORK/rt"; : > "$WORK/curl.log"; : > "$WORK/path"
	( cd "$WORK" && PATH="$WORK/bin:$PATH" CURL_LOG="$WORK/curl.log" \
		FIXTURE_TARBALL="$WORK/release/actionlint.tar.gz" RUNNER_TEMP="$WORK/rt" \
		GITHUB_PATH="$WORK/path" ACTIONLINT_VERSION=v9.8.7 ACTIONLINT_SHA256="$1" \
		bash -e -o pipefail -c "$install" ) > "$WORK/install.out" 2>&1
	rc=$?
}

install_with "$good_sha"
check "the install with the matching sha256 succeeds" "0" "$rc"
check "and it asked for that version's linux_amd64 release asset" \
	"https://github.com/rhysd/actionlint/releases/download/v9.8.7/actionlint_9.8.7_linux_amd64.tar.gz" \
	"$(cat "$WORK/curl.log")"
check "and the extracted binary is the one put on PATH" "fixture actionlint" \
	"$("$(cat "$WORK/path")/actionlint")"

install_with "$(printf '%064d' 0)"
check "a tarball whose sha256 does not match is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and nothing was extracted from it" "0" \
	"$([ -e "$WORK/rt/actionlint-bin/actionlint" ] && echo 1 || echo 0)"
check "and nothing was put on PATH" "" "$(cat "$WORK/path")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
