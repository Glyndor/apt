#!/usr/bin/env bash
#
# scripts/distro-floor.sh is what .github/workflows/distro-floor.yml runs
# inside a fresh Debian or Ubuntu container to assert the README's table:
# the releases listed as supported install podup, the one listed as
# unsupported is refused with a message that names podman. The script runs
# once a week where nobody watches, so its own failure modes need exercising
# here: a check that says "as the README says" on every input is the shape
# standards/testing calls a cron hiding its failures.
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

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/scripts/distro-floor.sh"
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
# PATH, which is what "the product installed" looks like to `command -v`. The
# product name is one no machine has: the real podup is installed on the box
# this was written on, and `command -v podup` found it, so the "exit 0 but
# nothing installed" case passed for the wrong reason until the name changed.
run_floor() { # $1=expect  $2=installer path  $3=present|absent
	local expect="$1" fixture="$2" binary="$3"
	rm -rf "$WORK/prod"; mkdir -p "$WORK/prod"
	if [ "$binary" = present ]; then
		printf '#!/bin/sh\nexit 0\n' > "$WORK/prod/$PRODUCT"; chmod +x "$WORK/prod/$PRODUCT"
	fi
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

# --- an unsupported release: refused, and the refusal names podman ---------

out="$(run_floor refuse "$(installer "$REFUSAL" 1)" absent)"; rc=$?
check "refuse: exit 1 naming podman (>= 5.0) passes" "0" "$rc"
check "and says it is refused, as the README says" "1" \
	"$(printf '%s' "$out" | grep -c 'refused here and the refusal names podman')"

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
check "and says the refusal does not name podman" "1" \
	"$(printf '%s' "$out" | grep -c 'does not name podman (>= 5.0)')"

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
check "the workflow matrix lists three images" "3" "$(printf '%s\n' "$matrix" | grep -c .)"
check "the README table names the same images with the same expectation" \
	"$(printf '%s\n' "$matrix" | LC_ALL=C sort)" "$(printf '%s\n' "$readme" | LC_ALL=C sort)"
check "and includes one release expected to refuse" "1" \
	"$(printf '%s\n' "$matrix" | grep -c ' refuse$')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
