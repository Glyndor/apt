#!/usr/bin/env bash
#
# What the by-hash copies are for, shown with a real apt client. A publish
# replaces the index files under their fixed names before it replaces InRelease,
# so for a moment the archive serves the InRelease of one build and the Packages
# of the next. A client that asks for Packages by name in that moment gets bytes
# its InRelease does not declare, and `apt update` fails with a hash mismatch.
# With `Acquire-By-Hash: yes` in the signed index, apt asks for
# by-hash/SHA256/<the hash it read>, which still holds the bytes it expects.
#
# The archive is served from a local HTTP server that records every path asked
# for, and apt runs with its own configuration, lists and cache, as the current
# user, reading nothing of the host's. Three cases:
#
#   * the midway archive, signed by scripts/build/add-by-hash.sh: apt updates,
#     asks only for by-hash names, and offers the version its InRelease declares;
#   * the same midway archive with an index signed without the field, which is
#     the archive before this change: apt fails with the mismatch, so the first
#     case passes because of the copies and not because the moment was missed;
#   * the archive once the new InRelease has landed: apt offers the new version.
#
# Requires: apt-get, apt-cache, gpg, gpgv, gzip, curl, python3.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/build/add-by-hash.sh"
WORK="$(mktemp -d)"
export GNUPGHOME="$WORK/gnupg" LC_ALL=C
mkdir -m 700 "$GNUPGHOME"
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	timeout 10 gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

for tool in apt-get apt-cache gpg gpgv gzip curl python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "NOTE  $tool is missing, so nothing below could run. Not a pass."; exit 1; }
done
# shellcheck source=tests/fixtures/build/unsigned-dist.sh
. "$HERE/tests/fixtures/build/unsigned-dist.sh"

gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key 'by-hash apt test <by-hash@test.invalid>' ed25519 sign never >/dev/null 2>&1
FPR="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
gpg --batch --armor --export "$FPR" > "$WORK/archive-key.asc" 2>/dev/null
gpg --batch --export "$FPR" > "$WORK/archive-key.gpg" 2>/dev/null

# Two builds, 1.0 then 2.0, each offered by hash and signed; and the first one
# again, signed the way the archive was signed before, with no field and no copies.
mkdist "$WORK/old" 1.0
mkdist "$WORK/new" 2.0
mkdist "$WORK/plain" 1.0
cp "$WORK/old/dists/stable/Release" "$WORK/plain/dists/stable/Release"
for build in old new; do
	bash "$SCRIPT" "$WORK/$build/dists/stable" "$FPR" "$WORK/archive-key.asc" >/dev/null \
		|| { echo "FAIL  the $build build could not be offered by hash"; exit 1; }
done
gpg --batch --yes --local-user "$FPR" --clearsign --output "$WORK/plain/dists/stable/InRelease" "$WORK/plain/dists/stable/Release"
check "the build without the field really has none" "0" "$(grep -c '^Acquire-By-Hash:' "$WORK/plain/dists/stable/InRelease")"

# The moment inside a publish: the new index files and their copies are in
# place, the InRelease (and the Release beside it) is still the old one.
midway() { # $1=destination $2=the build whose InRelease is served
	local arch copies
	rm -rf "$1"; cp -a "$WORK/new" "$1"
	for arch in amd64 arm64; do
		copies="$WORK/$2/dists/stable/main/binary-$arch/by-hash/SHA256"
		[ -d "$copies" ] && cp -a "$copies/." "$1/dists/stable/main/binary-$arch/by-hash/SHA256/"
	done
	cp "$WORK/$2/dists/stable/InRelease" "$WORK/$2/dists/stable/Release" "$1/dists/stable/"
}
SITE="$WORK/site"
midway "$SITE" old

# A server that records the path of every request, so a case can say which
# names apt asked for.
PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 - "$SITE" "$PORT" "$WORK/requests" <<'PY' >/dev/null 2>&1 &
import functools, http.server, sys
site, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        with open(log, "a") as fh:
            fh.write(self.path + "\n")
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=site)).serve_forever()
PY
SERVER_PID=$!
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
	curl -fsS --max-time 2 "$BASE/dists/stable/Release" -o /dev/null 2>/dev/null && break
	sleep 0.2
done
curl -fsS --max-time 2 "$BASE/dists/stable/Release" -o /dev/null \
	|| { echo "FAIL  the local HTTP server never came up on $PORT"; exit 1; }

# One isolated apt: its own configuration, sources, lists, cache and log.
apt_update() { # $1=name -> rc; output in $WORK/apt-$1.log
	local state="$WORK/apt-$1"
	rm -rf "$state"
	mkdir -p "$state/etc/parts" "$state/etc/sources.list.d" "$state/etc/trusted.gpg.d" "$state/etc/preferences.d" \
		"$state/state/lists/partial" "$state/cache/archives/partial" "$state/log"
	: > "$state/state/status"
	printf 'deb [arch=amd64 signed-by=%s] %s stable main\n' "$WORK/archive-key.gpg" "$BASE" > "$state/etc/sources.list"
	cat > "$state/config" <<EOF
Dir "$state";
Dir::Etc "$state/etc";
Dir::Etc::parts "$state/etc/parts";
Dir::Etc::main "$state/etc/apt.conf";
Dir::Etc::trusted "$state/etc/trusted.gpg";
Dir::Etc::trustedparts "$state/etc/trusted.gpg.d";
Dir::State "$state/state";
Dir::State::status "$state/state/status";
Dir::Cache "$state/cache";
Dir::Log "$state/log";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
APT::Sandbox::User "$(id -un)";
APT::Update::Error-Mode "any";
Acquire::Languages "none";
Acquire::Retries "0";
Acquire::http::Proxy "DIRECT";
Acquire::AllowInsecureRepositories "false";
EOF
	: > "$WORK/requests"
	APT_CONFIG="$state/config" apt-get update > "$WORK/apt-$1.log" 2>&1
}
candidate() { APT_CONFIG="$WORK/apt-$1/config" apt-cache policy fixture | awk '/Candidate:/ { print $2 }'; }
asked() { grep -c -- "$1" "$WORK/requests"; }

# --- the moment inside a publish, with the copies ------------------------------------
rc=0; apt_update by-hash || rc=$?
check "apt updates from the midway archive when the index is offered by hash" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$WORK/apt-by-hash.log"
check "and offers the version its InRelease declares" "1.0" "$(candidate by-hash)"
check "it asked for the index by its hash" "1" "$([ "$(asked '/by-hash/SHA256/')" -ge 1 ] && echo 1 || echo 0)"
check "and never by its fixed name" "0" "$(grep -cE '/binary-amd64/Packages(\.gz)?$' "$WORK/requests")"

# --- the same moment, with the index signed as it was before ----------------------
midway "$SITE" plain
rc=0; apt_update plain || rc=$?
check "the same midway archive without the field fails apt update" "100" "$rc"
check "on the index whose bytes are not the declared ones" "1" \
	"$(grep -cE 'Hash Sum mismatch|unexpected size|Mirror sync in progress' "$WORK/apt-plain.log" | awk '{ print ($1 > 0) }')"
check "having asked for it by its fixed name" "1" "$([ "$(grep -cE '/binary-amd64/Packages(\.gz)?$' "$WORK/requests")" -ge 1 ] && echo 1 || echo 0)"

# --- once the new InRelease has landed ---------------------------------------------
midway "$SITE" new
rc=0; apt_update landed || rc=$?
check "apt updates once the new InRelease is served" "0" "$rc"
check "and offers the new version" "2.0" "$(candidate landed)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
