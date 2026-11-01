#!/usr/bin/env bash
#
# The installer's limits and its behaviour under a pipe, split from
# install-template-behaviour.test.sh so neither file passes the line limit:
#   * a download over the byte caps, over a real http transfer;
#   * a package that unpacks past the ceiling, or is compressed twice;
#   * delivery through a pipe, as `curl ... | sudo sh` delivers it, with children
#     that read stdin;
#   * cleanup after an interrupt.
#
# Requires: gpg, dpkg-deb, curl, ar, python3.
# shellcheck disable=SC1091 # the path is built at run time
# shellcheck disable=SC2154 # pass and fail are counted by the sourced fixture
. "$(cd "$(dirname "$0")/../fixtures/installer" && pwd)/fixture.sh"

# --- delivered through a pipe, as `curl ... | sudo sh` delivers it ----------------
#
# The shell reads the script from stdin as it goes. A child that also reads stdin
# (dpkg and apt-get can, when they ask something) swallows the rest of the
# script, and dash then ends quietly with status 0 having run half of it. Every
# command the installer runs takes its stdin from /dev/null for that reason; the
# stubs here read stdin the way a hungry child would.
pipebin="$WORK/pipebin"; rm -rf "$pipebin"; cp -r "$BIN" "$pipebin"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$pipebin/apt-get"
cat > "$pipebin/dpkg" <<'STUB'
#!/bin/sh
cat >/dev/null
case "$1" in
	-i) echo "$*" >> "$DPKG_MARKER" ;;
esac
exit 0
STUB
chmod +x "$pipebin/apt-get" "$pipebin/dpkg"
DEB="$(mkdeb good good no)"
rm -f "$WORK/marker"
# 200 KB of comments right after the signature check, so that when dpkg runs the
# rest of the script is still in the pipe and not in the shell's read buffer.
sed -e 's/@PRODUCT@/testpkg/g' \
	-e '/^step "Package signature verified"$/r /dev/stdin' "$TEMPLATE" \
	< <(head -c 200000 /dev/zero | tr '\0' 'x' | fold -w 100 | sed 's/^/# /') > "$WORK/install.sh"
rc=0
env -i PATH="$pipebin:$PATH" HOME="$WORK" WORK="$WORK" \
	DPKG_MARKER="$WORK/marker" KEYRING_URL="file://$DEB" GLYNDOR_APT_FPR="$FPR_GOOD" \
	/bin/sh <"$WORK/install.sh" >"$WORK/out" 2>&1 || rc=$?
check "piped to sh, with children that read stdin, the installer still succeeds" "0" "$rc"
check "and it ran to the end: the product was verified after the install" "1" "$(said 'v9.9.9')"

# --- an interrupt is cleaned up after ------------------------------------------
#
# dash does not run the EXIT trap when a signal ends the shell. A Ctrl-C in the
# middle of `curl | sudo sh` left the work directory behind; the installer turns
# INT and TERM into an exit so the trap runs. TERM is what a background job can
# be sent here (a non-interactive shell starts background jobs ignoring INT).
slowbin="$WORK/slowbin"; rm -rf "$slowbin"; cp -r "$BIN" "$slowbin"
cat > "$slowbin/curl" <<'STUB'
#!/bin/sh
echo "$$" > "$WORK/curl.pid"
sleep 30
STUB
chmod +x "$slowbin/curl"
tmpdir="$WORK/tmp-int"; rm -rf "$tmpdir"; mkdir -p "$tmpdir"
env -i PATH="$slowbin:$PATH" HOME="$WORK" WORK="$WORK" TMPDIR="$tmpdir" KEYRING_URL="https://invalid.example/x.deb" \
	GLYNDOR_APT_FPR="$FPR_GOOD" /bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1 &
inst=$!
for _ in $(seq 1 50); do [ -s "$WORK/curl.pid" ] && break; sleep 0.1; done
kill -TERM "$inst" 2>/dev/null
kill "$(cat "$WORK/curl.pid" 2>/dev/null)" 2>/dev/null
wait "$inst" 2>/dev/null
check "after an interrupt the work directory is gone" "0" "$(find "$tmpdir" -mindepth 1 | wc -l | tr -d ' ')"
rm -f "$WORK/curl.pid"

# --- a small download that unpacks to gigabytes ------------------------------
#
# The 8 MB cap is on the compressed bytes. Zeroes compress to almost nothing, so
# this package is a few kilobytes on the wire and 20 MB once unpacked, in every
# respect valid and signed. Unpacking runs as root before any fingerprint is
# compared, so the unpacked size has its own ceiling.
bomb="$WORK/pkg-bomb"
rm -rf "$bomb"; mkdir -p "$bomb/DEBIAN" "$bomb/usr/share/keyrings" "$bomb/usr/share/doc"
printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
	> "$bomb/DEBIAN/control"
export_ring good "$bomb/usr/share/keyrings/glyndor.gpg"
head -c $((20 * 1024 * 1024)) /dev/zero > "$bomb/usr/share/doc/zeroes"
dpkg-deb -Zxz --root-owner-group --build "$bomb" "$WORK/bomb.deb" >/dev/null 2>&1
sign_deb good "$WORK/bomb.deb"
check "the bomb really is small on the wire" "1" "$([ "$(stat -c%s "$WORK/bomb.deb")" -lt $((1024 * 1024)) ] && echo 1 || echo 0)"
rc=0; run_installer "$WORK/bomb.deb" "$FPR_GOOD" || rc=$?
check "a package that unpacks past the ceiling is refused" "1" "$rc"
check "and the message says it unpacks to more than 8 MB" "1" "$(said 'unpacks to more than 8 MB')"
check "and nothing was installed" "0" "$(installed)"

# --- the byte caps over a real HTTP transfer ------------------------------------
#
# file:// never reaches curl's --max-filesize or its clock, so those flags could
# be deleted with every case above green (measured). A local server announces a
# body over each cap. The bytes are real and finite on purpose: a stream that
# never ends only proves that something, perhaps a full disk, stopped it, and it
# fills the disk if the cap is the thing being removed. With the cap the refusal
# is "could not download"; without it the download succeeds and the installer
# fails later, with a different message.
mkdir -p "$WORK/srv"
cat > "$WORK/srv/serve.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = sys.argv[2]

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path == "/big.deb":
            data = b"\0" * (9 * 1024 * 1024)
        elif self.path in ("/sigbig.deb.asc",):
            data = b"x" * (100 * 1024)
        elif self.path in ("/good.deb", "/sigbig.deb"):
            data = open(ROOT + "/good.deb", "rb").read()
        elif self.path == "/good.deb.asc":
            data = open(ROOT + "/good.deb.asc", "rb").read()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
cp "$(mkdeb good good no)" "$WORK/srv/good.deb"; cp "$WORK/good.deb.asc" "$WORK/srv/good.deb.asc"
HTTP_PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 "$WORK/srv/serve.py" "$HTTP_PORT" "$WORK/srv" >/dev/null 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$HTTP_PORT/good.deb.asc" >/dev/null 2>&1 && break; sleep 0.1; done
run_installer_url() { # $1=url  $2=fingerprint
	rm -f "$WORK/marker"
	sed 's/@PRODUCT@/testpkg/g' "$TEMPLATE" > "$WORK/install.sh"
	env -i PATH="$BIN:$PATH" HOME="$WORK" WORK="$WORK" DPKG_MARKER="$WORK/marker" \
		KEYRING_URL="$1" GLYNDOR_APT_FPR="$2" \
		timeout 60 /bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1
}
rc=0; run_installer_url "http://127.0.0.1:$HTTP_PORT/good.deb" "$FPR_GOOD" || rc=$?
check "over http, a real keyring is accepted (the control for the cases below)" "0" "$rc"
rc=0; run_installer_url "http://127.0.0.1:$HTTP_PORT/big.deb" "$FPR_GOOD" || rc=$?
check "a package body over the byte cap is refused" "1" "$rc"
check "and it is refused at the download, naming the cap" "1" "$(said '.deb (over 8 MB')"
check "and nothing was installed" "0" "$(installed)"
rc=0; run_installer_url "http://127.0.0.1:$HTTP_PORT/sigbig.deb" "$FPR_GOOD" || rc=$?
check "a signature body over its byte cap is refused" "1" "$rc"
check "and it is refused at the signature download, naming the cap" "1" "$(said '.asc (over 64 KB')"
check "and nothing was installed" "0" "$(installed)"
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true

# --- a data archive compressed twice -------------------------------------------
#
# dpkg-deb --fsys-tarfile undoes one layer. If the data member is gzip inside
# gzip, what comes out is still gzip, small enough to pass the ceiling, and tar
# given a file name would decompress it a second time past the ceiling. Built by
# hand with ar, since dpkg-deb would never write it.
twice="$WORK/pkg-twice"
rm -rf "$twice"; mkdir -p "$twice/data/usr/share/keyrings" "$twice/data/usr/share/doc" "$twice/control"
export_ring good "$twice/data/usr/share/keyrings/glyndor.gpg"
head -c $((20 * 1024 * 1024)) /dev/zero > "$twice/data/usr/share/doc/zeroes"
printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
	> "$twice/control/control"
printf '2.0\n' > "$twice/debian-binary"
tar -C "$twice/control" --owner=0 --group=0 -czf "$twice/control.tar.gz" .
tar -C "$twice/data" --owner=0 --group=0 -cf - . | gzip -9 | gzip -9 > "$twice/data.tar.gz"
( cd "$twice" && ar rc "$WORK/twice.deb" debian-binary control.tar.gz data.tar.gz )
sign_deb good "$WORK/twice.deb"
rc=0; run_installer "$WORK/twice.deb" "$FPR_GOOD" || rc=$?
check "a data archive compressed twice is refused" "1" "$rc"
check "and nothing was installed" "0" "$(installed)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
