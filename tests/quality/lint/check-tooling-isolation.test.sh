#!/usr/bin/env bash
# Behaviour tests for scripts/quality/lint/check-tooling-isolation.sh, the check
# reusable-workflow-lint.yml runs so that a job holding a secret does not also
# install third-party tooling.
#
# The rule used to see only the language installers (pip, cargo, npm...). It
# did not see `apt-get install` or `brew`, which install just as much while the
# job holds a secret (apt#361). Each case plants a workflow in a throwaway tree
# and runs the check exactly as it ships; the verdict is its exit status.
#
# The control: the same cases run against a copy of the check with the apt
# and brew detection switched off. Every case that expects a refusal on those
# shapes must then pass, otherwise the refusal was never the new rule's.
#
# Requires: python3 with PyYAML.
# The fixtures carry literal `${{ secrets.X }}`; single quotes are the point.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/lint/check-tooling-isolation.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

cp "$SCRIPT" "$WORK/real.sh"
# The control: no apt or brew detection. The patterns that match nothing keep
# the script intact in every other respect.
sed -e 's/^\( *APT_INSTALL_RE = re.compile(\)r"[^"]*"/\1r"(?!)"/' \
	-e 's/^\( *BREW_INSTALL_RE = re.compile(\)r"[^"]*"/\1r"(?!)"/' \
	-e 's/^\( *BREW_TOOL_RE = re.compile(\)r"[^"]*"/\1r"(?!)"/' \
	"$WORK/real.sh" > "$WORK/blind.sh"
check "the copy carries the install rules" "1" \
	"$(grep -c 'INSTALL_PATTERNS' "$WORK/real.sh" | awk '{print ($1>0)}')"
check "the control differs from the shipped check" "1" \
	"$(cmp -s "$WORK/real.sh" "$WORK/blind.sh" && echo 0 || echo 1)"
# The second control: the secret reaches the job only the way it used to be
# recognised, as secrets.<id> written in the job itself (issue #369).
python3 -I - "$WORK/real.sh" "$WORK/oldsecret.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
old_re = 'r"(?<!\\w)secrets\\.[A-Za-z_]\\w*"\n'
s, n1 = re.subn(r'r"\(\?<!\\w\)secrets\(\?:[^\n]*"\n', lambda m: old_re, s)
s, n2 = re.subn(r"SECRET_RE\.search\(job_text\) or env_carries_secret\(workflow_env\)", "SECRET_RE.search(job_text)", s)
assert n1 == 1 and n2 == 1, (n1, n2)
open(sys.argv[2], "w").write(s)
PY
check "the second control differs from the shipped check" "1" \
	"$(cmp -s "$WORK/real.sh" "$WORK/oldsecret.sh" && echo 0 || echo 1)"

# plant <secret: job|later|none> <run> [job-env] [step-env] [workflow-env]
# One job `build` with one step running <run>. `job` puts the secret in the job
# env, `later` in a following step, `none` nowhere.
plant() {
	local f="$WORK/t/.github/workflows/job.yml"
	mkdir -p "$WORK/t/.github/workflows"
	{
		printf 'name: Job\non: push\npermissions:\n  contents: read\n'
		[ -n "${5:-}" ] && printf 'env:\n  %s\n' "$5"
		printf 'jobs:\n  build:\n    runs-on: ubuntu-latest\n'
		if [ "$1" = job ] || [ -n "${3:-}" ]; then
			printf '    env:\n'
			[ "$1" = job ] && printf '      TOKEN: ${{ secrets.DEPLOY_TOKEN }}\n'
			[ -n "${3:-}" ] && printf '      %s\n' "$3"
		fi
		printf '    steps:\n      - run: |\n'
		printf '%s\n' "$2" | sed 's/^/          /'
		[ -n "${4:-}" ] && printf '        env:\n          %s\n' "$4"
		[ "$1" = later ] && printf '      - run: echo later\n        env:\n          TOKEN: ${{ secrets.DEPLOY_TOKEN }}\n'
	} > "$f"
}
verdict() { # <script> -> flag|pass
	if ( cd "$WORK/t" && bash "$1" >"$WORK/out" 2>&1 ); then echo pass; else echo flag; fi
}
# case <name> <expected> <class> <plant args...>; class: new = only the new rule decides
case_() {
	local name="$1" expected="$2" class="$3"; shift 3
	plant "$@"
	check "$name" "$expected" "$(verdict "$WORK/real.sh")"
	if [ "$class" = new ]; then
		check "  and without the new detection it is accepted" \
			"pass" "$(verdict "$WORK/blind.sh")"
	fi
	if [ "$class" = sec ]; then
		check "  and with the old way of finding the secret it is accepted" \
			"pass" "$(verdict "$WORK/oldsecret.sh")"
	fi
}

APT='sudo apt-get update -qq
sudo apt-get install -y -qq reprepro python3-cryptography'
case_ "pip install in a secret job" flag old job 'pip install requests'
case_ "pip install --require-hashes is exempt" pass old job 'pip install --require-hashes -r req.txt'
case_ "apt-get install, secret in the job env" flag new job "$APT"
case_ "apt-get install, secret only in a later step" pass new later "$APT"
case_ "apt install, secret in the job env" flag new job 'apt install -y somepackage'
case_ "apt-get install pinned to a version, secret later" pass new later 'sudo apt-get install -y curl=8.5.0-2'
case_ "apt-get install after add-apt-repository" flag new later 'sudo add-apt-repository ppa:x/y
sudo apt-get install -y tool'
case_ "apt-get install after a third-party sources.list" flag new later 'echo "deb https://x.example/apt stable main" | sudo tee /etc/apt/sources.list.d/x.list
sudo apt-get install -y tool'
case_ "apt-get install of a URL" flag new later 'sudo apt-get install -y https://x.example/tool.deb'
case_ "apt-get install of a local file" flag new later 'sudo apt-get install -y ./tool.deb'
case_ "apt-get install of a shell expansion" flag new later 'sudo apt-get install -y $(cat pkgs)'
case_ "apt-get install with the signature check off" flag new later 'sudo apt-get install -y --allow-unauthenticated tool'
case_ "apt-get install after a key in trusted.gpg.d" flag new later 'sudo cp k.gpg /etc/apt/trusted.gpg.d/
sudo apt-get install -y tool'
case_ "apt-get install, then a step reading glyndor-apt-key.asc with the secret" pass new later 'sudo apt-get install -y tool
gpg --show-keys keyring/glyndor-apt-key.asc'
case_ "brew install in a secret job" flag new job 'brew install someformula'
case_ "brew upgrade in a secret job" flag new job 'brew upgrade'
# `brew style` and `brew audit` install Ruby gems from RubyGems when the ones
# they need are missing, and HOMEBREW_NO_AUTO_UPDATE does not stop that, so the
# variable exempts neither of them wherever it is set. Only a job with no
# secret may run them.
case_ "brew style in a secret job" flag new job 'brew style Formula/*.rb'
case_ "brew audit in a secret job" flag new job 'brew audit --strict podup'
case_ "brew style with HOMEBREW_NO_AUTO_UPDATE in the job env" flag new job 'brew style Formula/*.rb' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew style with HOMEBREW_NO_AUTO_UPDATE in the step env" flag new job 'brew style Formula/*.rb' '' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew style with HOMEBREW_NO_AUTO_UPDATE in the workflow env" flag new job 'brew style Formula/*.rb' '' '' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew audit, secret only in a later step" flag new later 'brew audit --strict podup' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew style and brew audit in a job with no secret" pass none none 'brew style Formula/*.rb
brew audit --strict podup'
case_ "the same install in a job with no secret" pass old none "$APT"
case_ "an install that only appears in a comment" pass old job '# sudo apt-get install -y tool'

# --- where the secret comes from (issue #369) ---------------------------------
case_ "brew install, secret indexed with single quotes in the job env" flag sec none 'brew install x' "TOKEN: \${{ secrets['DEPLOY_TOKEN'] }}"
case_ "brew install, secret indexed with double quotes in the job env" flag sec none 'brew install x' 'TOKEN: ${{ secrets["DEPLOY_TOKEN"] }}'
case_ "apt-get install, secret in the workflow env" flag sec none "$APT" '' '' 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}'
case_ "apt-get install, secret indexed in the workflow env" flag sec none "$APT" '' '' "TOKEN: \${{ secrets['DEPLOY_TOKEN'] }}"
case_ "apt-get install, workflow env holding no secret" pass none none "$APT" '' '' 'LANG: C'


new() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/.github/workflows"; printf '%s' "$WORK/t"; }
run_in() { # $1=dir $2=script -> stdout+stderr, status in $?
	( cd "$1" && bash "$2" 2>&1 )
}
said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

# ===========================================================================
# A job holding a secret must not install third-party tooling
# ===========================================================================

tooling_case() { # $1=dir $2=env line (or empty) $3=run line
	cat > "$1/.github/workflows/job.yml" <<EOF
name: Job
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      $2
    steps:
      - run: |
          $3
EOF
}

# --- a secret plus a pip install is refused, and named --------------------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'pip install requests'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a job holding a secret that pip installs is refused" "1" "$rc"
check "and the message names the job and the line" "1" \
	"$(said "$out" 'job `build` installs third-party tooling while holding a secret: `pip install requests`')"

# --- the same install pinned by hash is the documented exemption ----------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'pip install --require-hashes -r req.txt'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "pip install --require-hashes while holding a secret is allowed" "0" "$rc"
check "and the step says nothing was found" "1" "$(said "$out" 'no job holding a secret installs')"

# --- cargo install has no hash exemption ---------------------------------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'cargo install --locked cargo-cyclonedx'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "cargo install --locked while holding a secret is still refused" "1" "$rc"

# --- the same install without a secret is fine ---------------------------
d="$(new)"; tooling_case "$d" 'PLAIN: value' 'cargo install --locked cargo-cyclonedx'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "the same install in a job holding no secret passes" "0" "$rc"

# --- a third-party action in a secret-holding job is refused ---------------
action_case() { # $1=dir $2=env line  $3=uses value
	cat > "$1/.github/workflows/job.yml" <<EOF
name: Job
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      $2
    steps:
      - uses: $3
EOF
}
d="$(new)"; action_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'someone/tool@0123456789abcdef0123456789abcdef01234567'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "an action from outside actions/ and github/ in a job holding a secret is refused" "1" "$rc"
check "and the message names the job and the action" "1" \
	"$(said "$out" 'job `build` installs third-party tooling while holding a secret: `uses: someone/tool@')"
d="$(new)"; action_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' 'actions/checkout@0123456789abcdef0123456789abcdef01234567'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "a GitHub-owned action in a job holding a secret passes" "0" "$rc"
d="$(new)"; action_case "$d" 'PLAIN: value' 'someone/tool@0123456789abcdef0123456789abcdef01234567'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "a third-party action in a job holding no secret passes" "0" "$rc"
d="$(new)"; action_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' './.github/workflows/reusable-x.yml'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "a local reusable in a job holding a secret passes" "0" "$rc"

# --- a commented-out install is not an install ---------------------------
d="$(new)"; tooling_case "$d" 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}' '# pip install requests'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "an install that only appears in a comment is not reported" "0" "$rc"

# --- a secret referenced in a step, not the job env, still counts --------
d="$(new)"
cat > "$d/.github/workflows/job.yml" <<'EOF'
name: Job
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: go install example.com/tool@v1
      - run: echo "$KEY"
        env:
          KEY: ${{ secrets.SIGNING_KEY }}
EOF
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "a secret held by a later step of the same job still counts" "1" "$rc"

# --- a `secrets:` declaration is not a reference -------------------------
d="$(new)"
cat > "$d/.github/workflows/job.yml" <<'EOF'
name: Job
on: push
permissions:
  contents: read
jobs:
  call:
    uses: ./.github/workflows/reusable-x.yml
    secrets: inherit
  build:
    runs-on: ubuntu-latest
    steps:
      - run: go install example.com/tool@v1
EOF
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "secrets: inherit on a reusable call is not a secret reference" "0" "$rc"

# --- an unparseable workflow is a warning, not a silent skip -------------
d="$(new)"; printf 'name: [\n' > "$d/.github/workflows/broken.yml"
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a workflow that does not parse does not fail the step" "0" "$rc"
check "but is reported as skipped, so the silence is visible" "1" "$(said "$out" '::warning')"

# ===========================================================================
# A job whose token can write must not install third-party tooling
# ===========================================================================
#
# The job token reaches every step whether a step names it or not, so it is a
# secret exactly when the job's permissions let it write. Each refusal is
# paired with the same job read-only, which passes.
token_case() { # $1=workflow permissions (or -) $2=job permissions (or -) $3=run line
	{
		printf 'name: Job\non: push\n'
		[ "$1" = - ] || printf 'permissions:\n  %s\n' "$1"
		printf 'jobs:\n  build:\n    runs-on: ubuntu-latest\n'
		[ "$2" = - ] || printf '    permissions:\n      %s\n' "$2"
		printf '    steps:\n      - run: %s\n' "$3"
	} > "$WORK/t/.github/workflows/job.yml"
}
d="$(new)"; token_case - 'contents: write' 'pip install requests'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a job whose token can write that pip installs is refused" "1" "$rc"
check "and refused for the token, naming the grant" "1" "$(said "$out" 'while its token can write (`contents: write`)')"
d="$(new)"; token_case - 'contents: read' 'pip install requests'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "the same install with a read-only token passes" "0" "$rc"
d="$(new)"; token_case 'contents: write' - 'cargo install --locked tool'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a write grant at the workflow level reaches a job that declares none" "1" "$rc"
d="$(new)"; token_case 'contents: write' 'contents: read' 'cargo install --locked tool'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "a job that declares read-only permissions overrides the workflow's write" "0" "$rc"
d="$(new)"; token_case - - 'npm install -g tool'
out="$(run_in "$d" "$SCRIPT")"; rc=$?
check "a job with no permissions at any level is refused" "1" "$rc"
check "and the message says the repository default applies" "1" "$(said "$out" 'repository default applies')"
d="$(new)"; printf 'name: Job\non: push\npermissions: write-all\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: brew install x\n' > "$d/.github/workflows/job.yml"
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "permissions: write-all with an install is refused" "1" "$rc"
d="$(new)"; token_case - 'contents: write' 'sudo apt-get install -y jq'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "an install from the distribution's archive with a write token passes, as with a secret" "0" "$rc"
d="$(new)"; token_case - 'contents: write' 'echo nothing installed'
rc=0; run_in "$d" "$SCRIPT" >/dev/null || rc=$?
check "a write token in a job that installs nothing passes" "0" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
