#!/usr/bin/env bash
# Full-body read-back, independent of signatures and local HTTP sockets.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-installers.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() {
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail + 1))
	fi
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }
"$HERE/scripts/build/build-installers.sh" "$WORK/expected" podup epistle >/dev/null || exit 1
mkdir -p "$WORK/site/install"
reset_site() { cp "$WORK/expected/"* "$WORK/site/install/"; }
run() {
	rc=0
	"$VERIFY" "file://$WORK/site" "$WORK/expected" podup epistle > "$WORK/out" 2>&1 || rc=$?
}
reset_site; run
check 'both complete generated installers pass' 0 "$rc"
check 'the last product is compared too' 1 "$(said 'installer matches generated content for epistle')"

printf '#!/bin/sh\n' > "$WORK/site/install/podup"
run
check 'a one-line shebang is rejected' 1 "$rc"
check 'the shebang rejection names the content mismatch' 1 "$(said 'installer content differs at')"

reset_site
cp "$WORK/expected/epistle" "$WORK/site/install/podup"
run
check 'another complete product script with a shebang is rejected' 1 "$rc"
check 'the wrong-product rejection names the content mismatch' 1 "$(said 'installer content differs at')"

reset_site
head -c 1000 "$WORK/expected/podup" > "$WORK/site/install/podup"
run
check 'a truncated body returned successfully is rejected' 1 "$rc"
check 'the truncation is a content mismatch' 1 "$(said 'installer content differs at')"

reset_site
python3 - "$WORK/site/install/podup" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_bytes()
assert b'upgrades and archive-key renewals' in data
p.write_bytes(data.replace(b'upgrades and archive-key renewals', b'UPGRADES and archive-key renewals'))
PY
run
check 'a same-size change near the end of the body is rejected' 1 "$rc"
check 'the same-size change is a content mismatch' 1 "$(said 'installer content differs at')"

reset_site
rm "$WORK/site/install/epistle"
run
check 'a missing last installer is rejected' 1 "$rc"
check 'the missing installer is named as a transfer failure' 1 "$(said 'installer transfer failed at file://')"
check 'the failed URL names the last product' 1 "$(said '/install/epistle')"

# A failed transfer can leave even the expected bytes behind. Checking cmp
# alone would pass this; curl's status is a separate part of the contract.
reset_site
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'SH'
#!/bin/sh
out=; url=
for arg; do
	if [ "$out" = next ]; then out=$arg; fi
	[ "$arg" != -o ] || out=next
	case "$arg" in file://*) url=$arg ;; esac
done
cp "${url#file://}" "$out" || exit 99
echo 'curl: (18) end of response with bytes missing' >&2
exit 18
SH
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH" run
check 'a failed transfer is rejected even with matching bytes' 1 "$rc"
check 'the transfer failure is diagnosed separately from a mismatch' 1 "$(said 'installer transfer failed at')"
check 'the curl partial-file diagnostic is preserved' 1 "$(said 'curl: (18)')"

# Execute both actual workflow entry points, without the unrelated archive
# signature steps. A deleted invocation must not look like a successful check.
mkdir -p "$WORK/root/.github/workflows" "$WORK/root/public/install"
cp -r "$HERE/scripts" "$WORK/root/scripts"
cp "$WORK/expected/"* "$WORK/root/public/install/"
printf 'env:\n  PRODUCTS: "podup epistle:amd64"\n' > "$WORK/root/.github/workflows/publish.yml"
for workflow in health-check publish; do
	if [ "$workflow" = health-check ]; then
		step='Advertised installers reachable'
	else
		step='Verify the published installers match the build'
	fi
	python3 - "$HERE/.github/workflows/$workflow.yml" "$step" > "$WORK/step.sh" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, line in enumerate(lines) if 'name: ' + sys.argv[2] in line)
run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == 'run: |')
for line in lines[run + 1:]:
    if line.strip() and not line.startswith(' ' * 10):
        break
    print(line[10:])
PY
	workflow_run() {
		rc=0
		(cd "$WORK/root" && BASE_URL="file://$WORK/site" ARCHIVE_URL="file://$WORK/site" \
			PRODUCTS='podup epistle:amd64' bash "$WORK/step.sh") > "$WORK/out" 2>&1 || rc=$?
	}
	reset_site; workflow_run
	check "$workflow accepts the complete generated bodies" 0 "$rc"
	check "$workflow invokes the verifier through the last product" 1 "$(said 'installer matches generated content for epistle')"
	printf '#!/bin/sh\n' > "$WORK/site/install/podup"
	workflow_run
	check "$workflow rejects the one-line script" 1 "$rc"
	check "$workflow diagnoses the body mismatch" 1 "$(said 'installer content differs at')"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
