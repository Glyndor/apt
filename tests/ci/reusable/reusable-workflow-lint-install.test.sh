#!/usr/bin/env bash
# Behaviour tests for the install rule, the assertion "A job
# holding a secret must not install third-party tooling" in
# .github/workflows/reusable-workflow-lint.yml.
#
# The rule used to see only the language installers (pip, cargo, npm...). It
# did not see `apt-get install` or `brew`, which install just as much while the
# job holds a secret (apt#361). Each case plants a workflow in a throwaway tree
# and runs the assertion exactly as it ships; the verdict is its exit status.
#
# The control: the same cases run against a copy of the assertion with the apt
# and brew detection switched off. Every case that expects a refusal on those
# shapes must then pass, otherwise the refusal was never the new rule's.
#
# Requires: python3 with PyYAML.
# The fixtures carry literal `${{ secrets.X }}`; single quotes are the point.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

step_script() { # $1=workflow $2=step name substring
	python3 -I - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if line.strip() and not line.startswith(" " * 10):
        break
    body.append(line[10:] if line.strip() else "")
print("\n".join(body))
PY
}

STEP="A job holding a secret must not install"
step_script "$HERE/.github/workflows/reusable-workflow-lint.yml" "$STEP" > "$WORK/real.sh"
# The control: no apt or brew detection. The patterns that match nothing keep
# the script intact in every other respect.
sed -e 's/^\( *APT_INSTALL_RE = re.compile(\)r"[^"]*"/\1r"(?!)"/' \
	-e 's/^\( *BREW_INSTALL_RE = re.compile(\)r"[^"]*"/\1r"(?!)"/' \
	-e 's/^\( *BREW_TOOL_RE = re.compile(\)r"[^"]*"/\1r"(?!)"/' \
	"$WORK/real.sh" > "$WORK/blind.sh"
check "the assertion was extracted from the workflow" "1" \
	"$(grep -c 'INSTALL_PATTERNS' "$WORK/real.sh" | awk '{print ($1>0)}')"
check "the control differs from the shipped assertion" "1" \
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
check "the second control differs from the shipped assertion" "1" \
	"$(cmp -s "$WORK/real.sh" "$WORK/oldsecret.sh" && echo 0 || echo 1)"

# plant <secret: job|later|none> <run> [job-env] [step-env] [workflow-env]
# One job `build` with one step running <run>. `job` puts the secret in the job
# env, `later` in a following step, `none` nowhere.
plant() {
	local f="$WORK/t/.github/workflows/job.yml"
	mkdir -p "$WORK/t/.github/workflows"
	{
		printf 'name: Job\non: push\n'
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
case_ "brew style without HOMEBREW_NO_AUTO_UPDATE" flag new job 'brew style Formula/*.rb'
case_ "brew audit without HOMEBREW_NO_AUTO_UPDATE" flag new job 'brew audit --strict podup'
case_ "brew style with it set in the job env" pass new job 'brew style Formula/*.rb' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew style with it set in the step env" pass new job 'brew style Formula/*.rb' '' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew style with it set in the workflow env" pass new job 'brew style Formula/*.rb' '' '' 'HOMEBREW_NO_AUTO_UPDATE: "1"'
case_ "brew style with an empty value" flag new job 'brew style Formula/*.rb' 'HOMEBREW_NO_AUTO_UPDATE: ""'
case_ "brew style with the job value cleared by the step" flag new job 'brew style Formula/*.rb' 'HOMEBREW_NO_AUTO_UPDATE: "1"' 'HOMEBREW_NO_AUTO_UPDATE: ""'
case_ "the same install in a job with no secret" pass old none "$APT"
case_ "an install that only appears in a comment" pass old job '# sudo apt-get install -y tool'

# --- where the secret comes from (issue #369) ---------------------------------
case_ "brew install, secret indexed with single quotes in the job env" flag sec none 'brew install x' "TOKEN: \${{ secrets['DEPLOY_TOKEN'] }}"
case_ "brew install, secret indexed with double quotes in the job env" flag sec none 'brew install x' 'TOKEN: ${{ secrets["DEPLOY_TOKEN"] }}'
case_ "apt-get install, secret in the workflow env" flag sec none "$APT" '' '' 'TOKEN: ${{ secrets.DEPLOY_TOKEN }}'
case_ "apt-get install, secret indexed in the workflow env" flag sec none "$APT" '' '' "TOKEN: \${{ secrets['DEPLOY_TOKEN'] }}"
case_ "apt-get install, workflow env holding no secret" pass none none "$APT" '' '' 'LANG: C'

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
