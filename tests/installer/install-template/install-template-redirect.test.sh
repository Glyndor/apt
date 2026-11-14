#!/usr/bin/env bash
# Real curl and local TLS: neither package nor signature redirects may use HTTP.
# Requires: curl, openssl, python3, timeout. No external network or signing keys.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
SRV_PID=
pass=0; fail=0
cleanup() {
	if [ -n "$SRV_PID" ]; then
		kill "$SRV_PID" 2>/dev/null || true
		wait "$SRV_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
check() { # description, expected, actual
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1 (expected $2, actual $3)"; fail=$((fail + 1))
	fi
}
finish() {
	echo "$pass passed, $fail failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
	[ "$fail" -eq 0 ]
}
for tool in curl openssl python3 timeout; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		check "required tool: $tool" present missing
		finish; exit 1
	fi
done
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	-subj /CN=127.0.0.1 -addext 'subjectAltName=IP:127.0.0.1' \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" >"$WORK/tls.log" 2>&1; then
	cat "$WORK/tls.log"
	check 'local certificate generated' 0 1
	finish; exit 1
fi
cat > "$WORK/serve.py" <<'PY'
import pathlib
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

root = pathlib.Path(sys.argv[1])

class Target(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with (root / "http.log").open("a") as log:
            log.write(self.path + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "15")
        self.end_headers()
        self.wfile.write(b"untrusted bytes")

class Redirect(Target):
    def do_GET(self):
        with (root / "https.log").open("a") as log:
            log.write(self.path + "\n")
        if self.path in ("/package.deb", "/signature.deb.asc"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{http.server_port}/target")
        else:
            self.send_response(200)
        # An explicit length lets curl finish without a TLS close_notify.
        self.send_header("Content-Length", "0")
        self.end_headers()

http = HTTPServer(("127.0.0.1", 0), Target)
https = HTTPServer(("127.0.0.1", 0), Redirect)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / "cert.pem", root / "key.pem")
https.socket = context.wrap_socket(https.socket, server_side=True)
threading.Thread(target=http.serve_forever, daemon=True).start()
threading.Thread(target=https.serve_forever, daemon=True).start()
(root / "ports").write_text(f"{http.server_port} {https.server_port}\n")
threading.Event().wait()
PY
python3 -I "$WORK/serve.py" "$WORK" >"$WORK/server.log" 2>&1 &
SRV_PID=$!
for _ in {1..50}; do
	[ ! -s "$WORK/ports" ] || break
	kill -0 "$SRV_PID" 2>/dev/null || break
	sleep 0.1
done
if [ ! -s "$WORK/ports" ]; then
	cat "$WORK/server.log"
	check 'local servers started' 0 1
	finish; exit 1
fi
read -r HTTP_PORT HTTPS_PORT < "$WORK/ports"
# Positive controls prove both listeners work and curl trusts the TLS certificate.
rc=0
curl -q --noproxy '*' -fsS --max-time 5 "http://127.0.0.1:$HTTP_PORT/health" >/dev/null || rc=$?
check 'control: HTTP destination is reachable' 0 "$rc"
rc=0
curl -q --noproxy '*' --cacert "$WORK/cert.pem" -fsS --max-time 5 \
	"https://127.0.0.1:$HTTPS_PORT/health" >/dev/null || rc=$?
check 'control: HTTPS certificate and listener work' 0 "$rc"

mkdir -p "$WORK/bin" "$WORK/tmp"
# The installer refuses a temporary directory other users can write to.
chmod 700 "$WORK/tmp"
printf '#!/bin/sh\necho 0\n' > "$WORK/bin/id"
# Pretend to be root consistently with id, including temporary-directory owners.
printf '#!/bin/sh\necho 0\n' > "$WORK/bin/stat"
for tool in dpkg apt-get dpkg-deb gpg; do
	cat > "$WORK/bin/$tool" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$WORK/install-calls"
exit 1
STUB
done
chmod +x "$WORK/bin/"*
sed 's/@PRODUCT@/testpkg/g' "$HERE/scripts/installer/install-template.sh" > "$WORK/install.sh"
for resource in package signature; do
	: > "$WORK/http.log"; : > "$WORK/https.log"
	rm -f "$WORK/install-calls"
	rc=0
	env -i PATH="$WORK/bin:$PATH" HOME="$WORK" WORK="$WORK" TMPDIR="$WORK/tmp" \
		CURL_CA_BUNDLE="$WORK/cert.pem" NO_PROXY='*' \
		KEYRING_URL="https://127.0.0.1:$HTTPS_PORT/$resource.deb" \
		timeout 15 /bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1 || rc=$?
	check "$resource: installer refuses the redirect" 1 "$rc"
	check "$resource: HTTPS redirect endpoint was reached" 1 \
		"$(grep -cx "/$resource.deb$([ "$resource" != signature ] || printf '.asc')" "$WORK/https.log")"
	check "$resource: curl refuses the HTTP protocol" 1 \
		"$(grep -qi 'Protocol "http" disabled' "$WORK/out" && echo 1 || echo 0)"
	check "$resource: HTTP destination receives zero requests" 0 "$(wc -l < "$WORK/http.log" | tr -d ' ')"
	check "$resource: no dpkg, extraction or package installation calls" 0 \
		"$([ -e "$WORK/install-calls" ] && echo 1 || echo 0)"
	check "$resource: installer removes its temporary downloads" 0 \
		"$(find "$WORK/tmp" -mindepth 1 | wc -l | tr -d ' ')"
done
finish
