#!/usr/bin/env bash
#
# scripts/verify/distro-floor.sh is what .github/workflows/distro-floor.yml runs
# inside a fresh Debian or Ubuntu container to assert the README's table:
# the releases listed as supported install podup, the one listed as
# unsupported is refused with a message that names the floor. The script runs
# once a week where nobody watches, so its own failure modes need exercising
# here: a check that says "as the README says" on every input is a cron hiding
# its failures.
#
# The script is run as it ships, with apt-get and curl replaced by stubs on
# PATH and the installer replaced by a fixture that exits and prints what the
# case needs. No network, no container, no root.
#
# Not covered, and not coverable without the Actions engine: the `schedule:`
# trigger and the docker invocation itself.
#
# Requires: bash, sh, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/distro-floor.sh"
WORKFLOW="$HERE/.github/workflows/distro-floor.yml"
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

for tool in sh python3; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "NOTE  $tool is missing, so nothing below could run. Not a pass."
		exit 1
	}
done

# Stubs. apt-get does nothing. curl honours `-o <path>` by copying the
# fixture installer there, or fails when STUB_CURL_FAIL is set, which is what
# a missing or unreachable /install/<product> looks like to the script.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CURL_FAIL:-}" ] && exit 22
out=""; prev=""
for arg in "$@"; do
	[ "$prev" = "-o" ] && out="$arg"
	prev="$arg"
done
cp "${STUB_INSTALLER:?fixture installer required}" "$out"
STUB
chmod +x "$WORK/bin/apt-get" "$WORK/bin/curl"

# A fixture installer: prints $1 and exits $2.
installer() { # $1=text  $2=exit code
	printf '#!/bin/sh\nprintf %%s\\\\n "%s"\nexit %s\n' "$1" "$2" > "$WORK/installer.sh"
	echo "$WORK/installer.sh"
}

# Run the script as it ships. With $3=present a fake product binary sits on
# PATH, which is what "the product installed" looks like to `command -v`. With
# $3=broken the binary exits non-zero on --version, which is what a file on
# PATH that cannot start looks like. The product name is one no machine has:
# the real podup is installed on the box this was written on, and `command -v
# podup` found it, so the "exit 0 but nothing installed" case passed for the
# wrong reason until the name changed.
run_floor() { # $1=expect  $2=installer path  $3=present|absent|broken
	local expect="$1" fixture="$2" binary="$3"
	rm -rf "$WORK/prod"; mkdir -p "$WORK/prod"
	case "$binary" in
		present)
			# `exit 0` on every argument is what the previous check needed;
			# the new `--version` check needs it to keep doing that.
			printf '#!/bin/sh\nexit 0\n' > "$WORK/prod/$PRODUCT"
			;;
		broken)
			printf '#!/bin/sh\necho "cannot execute: required file not found" >&2\nexit 126\n' \
				> "$WORK/prod/$PRODUCT"
			;;
	esac
	[ "$binary" != absent ] && chmod +x "$WORK/prod/$PRODUCT"
	STUB_INSTALLER="$fixture" PATH="$WORK/bin:$WORK/prod:/usr/bin:/bin" \
		sh "$SCRIPT" "$expect" "$PRODUCT" 2>&1
}

PRODUCT=floor-probe
REFUSAL="$PRODUCT : Depends: podman (>= 5.0) but it is not going to be installed"

# --- a supported release: the installer succeeds and the product is there --

out="$(run_floor install "$(installer 'podup installed' 0)" present)"; rc=$?
check "install: installer exit 0 and the product on PATH passes" "0" "$rc"
check "and says it installs, as the README says" "1" \
	"$(printf '%s' "$out" | grep -c 'installs here, as the README says')"

# --- a supported release where the installer failed ------------------------

out="$(run_floor install "$(installer "$REFUSAL" 1)" absent)"; rc=$?
check "install: an installer that exits 1 fails" "1" "$rc"
check "and names the exit code and the README" "1" \
	"$(printf '%s' "$out" | grep -c 'exited 1 on a release the README lists as supported')"
check "and prints the installer's own output" "1" \
	"$(printf '%s' "$out" | grep -c 'Depends: podman')"

# --- exit 0 with nothing installed is not a pass ---------------------------
#
# An installer that exits 0 without installing (a wrong product name served
# as an empty page, a script cut short) must not read as "installs here".

out="$(run_floor install "$(installer 'nothing to do' 0)" absent)"; rc=$?
check "install: exit 0 but no binary on PATH fails" "1" "$rc"
check "and says the binary is missing" "1" \
	"$(printf '%s' "$out" | grep -c "exited 0 but $PRODUCT is not on PATH")"

# --- a binary on PATH that cannot start fails ------------------------------
#
# `command -v` admits a file on PATH that exits non-zero on --version, and
# the installer that put it there did not notice: dpkg records the package
# the binary came from, not whether the binary itself runs. The second check
# is what turns "on PATH" into "runs", and the assertion below is what keeps
# it that way.
out="$(run_floor install "$(installer 'unused' 0)" broken)"; rc=$?
check "install: a binary on PATH that cannot start fails" "1" "$rc"
check "and says it does not start" "1" \
	"$(printf '%s' "$out" | grep -c 'does not start')"

# --- an unsupported release: refused, and the refusal names libc6 (>= 2.39) -

# The release is refused by the archive's own podman: its glibc is too old.
out="$(run_floor refuse "$(installer "$PRODUCT : Depends: libc6 (>= 2.39) but 2.35-0ubuntu3 is to be installed" 1)" absent)"; rc=$?
check "refuse: exit 1 naming libc6 (>= 2.39) passes" "0" "$rc"
check "and says it is refused, as the README says" "1" \
	"$(printf '%s' "$out" | grep -c 'refused here and the refusal names the floor')"

# Two refusals that are not the floor the README documents: another package, and another number.
# Each is paired with the case above, the same shape naming libc6 (>= 2.39), which passes.
out="$(run_floor refuse "$(installer "$REFUSAL" 1)" absent)"; rc=$?
check "refuse: a refusal that names podman (>= 5.0) and not libc6 fails" "1" "$rc"
check "and says the refusal does not name the floor" "1" \
	"$(printf '%s' "$out" | grep -c 'does not name the floor: libc6 (>= 2.39)')"
out="$(run_floor refuse "$(installer "$PRODUCT : Depends: libc6 (>= 2.35) but 2.31-0ubuntu3 is to be installed" 1)" absent)"; rc=$?
check "refuse: a refusal that names another libc6 floor fails" "1" "$rc"
check "and says the refusal does not name the floor" "1" \
	"$(printf '%s' "$out" | grep -c 'does not name the floor: libc6 (>= 2.39)')"

# --- an unsupported release that installed anyway --------------------------
#
# This is the case the check exists for: the release grew podman 5 (or a
# backport), the README still lists it as unsupported, and the table is now
# wrong. It must go red, not quietly pass.

out="$(run_floor refuse "$(installer 'podup installed' 0)" present)"; rc=$?
check "refuse: an install that succeeds fails" "1" "$rc"
check "and says the README lists it as unsupported" "1" \
	"$(printf '%s' "$out" | grep -c 'succeeded on a release the README lists as unsupported')"

# --- refused for some other reason is not the floor ------------------------
#
# A refusal that does not name podman is a different defect (a broken mirror,
# a bad signature) wearing the expected exit code. It must not count.

out="$(run_floor refuse "$(installer 'error: apt could not install it' 1)" absent)"; rc=$?
check "refuse: exit 1 without podman in the output fails" "1" "$rc"
check "and says the refusal does not name the floor" "1" \
	"$(printf '%s' "$out" | grep -c 'does not name the floor')"

# --- the installer could not be downloaded ---------------------------------

out="$(STUB_CURL_FAIL=1 run_floor install "$(installer 'unused' 0)" present)"; rc=$?
check "a failed download fails" "1" "$rc"
check "and names the URL it could not fetch" "1" \
	"$(printf '%s' "$out" | grep -c "could not download https://apt.glyndor.net/install/$PRODUCT")"

# --- an expectation the script does not know -------------------------------

out="$(run_floor maybe "$(installer 'unused' 0)" present)"; rc=$?
check "an unknown expectation word fails" "1" "$rc"
check "and names it" "1" "$(printf '%s' "$out" | grep -c 'got: maybe')"

# --- the workflow runs this script, on schedule and dispatch only ----------

check "the workflow runs distro-floor.sh inside the container" "1" \
	"$(grep -c 'sh /distro-floor.sh' "$WORKFLOW")"
check "the workflow has no push or pull_request trigger" "0" \
	"$(grep -cE '^  (push|pull_request):' "$WORKFLOW")"
check "the workflow has a schedule" "1" "$(grep -c '^  schedule:' "$WORKFLOW")"
check "and workflow_dispatch" "1" "$(grep -c '^  workflow_dispatch:' "$WORKFLOW")"

# --- the README table and the workflow matrix are the same list ------------
#
# The README states which releases install and which is refused. That claim
# is only worth having because this workflow measures it, so the two lists
# must be one list: an image added to one and not the other is a promise
# nothing checks.

matrix="$(python3 - "$WORKFLOW" <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
image = None
for line in lines:
    m = re.match(r'\s*- image:\s*(\S+)', line)
    if m:
        image = m.group(1); continue
    m = re.match(r'\s*expect:\s*(\S+)', line)
    if m and image:
        print(f"{image} {m.group(1)}"); image = None
PY
)"
readme="$(python3 - "$HERE/README.md" <<'PY'
import sys, re
for line in open(sys.argv[1]):
    m = re.match(r'\|\s*`([^`]+)`\s*\|\s*(installs|refused)', line)
    if m:
        print(f"{m.group(1)} {'install' if m.group(2) == 'installs' else 'refuse'}")
PY
)"
check "the workflow matrix lists five images" "5" "$(printf '%s\n' "$matrix" | grep -c .)"
check "the README table names the same images with the same expectation" \
	"$(printf '%s\n' "$matrix" | LC_ALL=C sort)" "$(printf '%s\n' "$readme" | LC_ALL=C sort)"
# The floor the README prints is the one the script asks for.
readme_floor="$(grep -o 'libc6 (>= [0-9.]*) but' "$HERE/README.md" | head -1 | sed 's/ but$//')"
script_floor="libc6 (>= $(sed -n 's/^floor_libc="\(.*\)"$/\1/p' "$SCRIPT"))"
check "the refusal the README quotes is the floor the script asks for" "$script_floor" "$readme_floor"
check "and the README says the floor in words too" "1" "$(grep -c 'The floor is glibc 2.39' "$HERE/README.md")"
check "and includes two releases expected to refuse" "2" \
	"$(printf '%s\n' "$matrix" | grep -c ' refuse$')"
check "and three expected to install" "3" \
	"$(printf '%s\n' "$matrix" | grep -c ' install$')"

# --- every product the archive serves, and the upgrade on the releases that install -----------------

# The products of the matrix are the PRODUCTS of publish.yml, so a product that joins the archive is
# measured with it, and the upgrade runs on the images that install and on no other.
shape="$(python3 -I - "$WORKFLOW" "$HERE/.github/workflows/publish.yml" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
products = sorted(re.search(r'^\s*PRODUCTS:\s*"([^"]*)"', open(sys.argv[2]).read(), re.M).group(1).replace(":amd64", "").split())
floor = wf["jobs"]["floor"]["strategy"]["matrix"]
upgrade = wf["jobs"]["upgrade"]["strategy"]["matrix"]
installs = sorted(i["image"] for i in floor["include"] if i["expect"] == "install")
on = wf.get("on", wf.get(True))
print("floor-products", sorted(floor["product"]) == products)
print("upgrade-products", sorted(upgrade["product"]) == products)
print("upgrade-images", sorted(upgrade["image"]) == installs)
print("floor-images", sorted(floor["image"]) == sorted(i["image"] for i in floor["include"]))
print("after-publish", on["workflow_run"] == {"workflows": ["Publish apt repository"], "types": ["completed"]})
print("no-pr", not ({"push", "pull_request", "pull_request_target"} & set(on)))
PY
)"
check "the floor job runs every product of publish.yml" "floor-products True" "$(printf '%s\n' "$shape" | grep '^floor-products')"
check "and so does the upgrade job" "upgrade-products True" "$(printf '%s\n' "$shape" | grep '^upgrade-products')"
check "the upgrade job runs on the images that install and on none that refuses" "upgrade-images True" "$(printf '%s\n' "$shape" | grep '^upgrade-images')"
check "every image of the floor job has its expectation" "floor-images True" "$(printf '%s\n' "$shape" | grep '^floor-images')"
check "the workflow also runs after each publication" "after-publish True" "$(printf '%s\n' "$shape" | grep '^after-publish')"
check "and on no push or pull request" "no-pr True" "$(printf '%s\n' "$shape" | grep '^no-pr')"
# The step that runs the upgrade refuses to start when the release before was not fetched, and never reaches docker.
mkdir -p "$WORK/step/previous" "$WORK/step/bin"
printf '#!/bin/sh\necho docker-was-called > "%s/docker.called"\n' "$WORK/step" > "$WORK/step/bin/docker"; chmod +x "$WORK/step/bin/docker"
python3 -I - "$WORKFLOW" > "$WORK/step/run.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["upgrade"]["steps"]
print([s for s in steps if s.get("name", "").startswith("Upgrade from it")][0]["run"])
PY
out="$(cd "$WORK/step" && RUNNER_TEMP="$WORK/step" PRODUCT=upg-probe IMAGE=x PATH="$WORK/step/bin:$PATH" bash run.sh 2>&1)"; rc=$?
check "an upgrade step with no package of the release before refuses" "1" "$rc"
check "and says so" "1" "$(printf '%s' "$out" | grep -c 'no package of the release before was fetched')"
check "and never reaches docker" "no" "$(test -e "$WORK/step/docker.called" && echo yes || echo no)"
printf 'x' > "$WORK/step/previous/upg-probe_1.0.0_amd64.deb"
( cd "$WORK/step" && RUNNER_TEMP="$WORK/step" PRODUCT=upg-probe IMAGE=x PATH="$WORK/step/bin:$PATH" bash run.sh >/dev/null 2>&1 )
check "and with a package it goes on to docker" "yes" "$(test -e "$WORK/step/docker.called" && echo yes || echo no)"
check "the upgrade job fetches the release before the served one and says nothing passes without it" "1" \
	"$(grep -c 'previous-release.sh' "$WORKFLOW")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
