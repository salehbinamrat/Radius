#!/usr/bin/env bash
# CI-only: independent PostgreSQL + TLS Kestrel + real admin cookie lifecycle.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(printenv CI || true)" == "true" && "$(printenv LAB_HTTPS_TEST_ACK || true)" == "isolated-ci" ]] || {
  echo "HTTPS acceptance requires isolated GitHub CI acknowledgement" >&2; exit 1;
}
[[ -f .env ]] || { echo "Isolated lab .env missing" >&2; exit 1; }
command -v openssl >/dev/null
command -v docker >/dev/null
command -v python3 >/dev/null
umask 077
tmp=$(mktemp -d)
mkdir -p "$tmp/tls"
# Test-only certificate. Production requires a trusted certificate and secure storage.
chmod 755 "$tmp" "$tmp/tls"
project="radiushttps$(python3 -c 'import secrets;print(secrets.token_hex(4))')"
compose_file=tests/admin-https.compose.yaml
cleanup() {
  if [[ "$project" =~ ^radiushttps[a-f0-9]{8}$ ]]; then
    docker compose -p "$project" -f "$compose_file" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT

schema_image=$(docker compose images -q schema-init)
api_image=$(docker compose images -q api)
[[ -n "$schema_image" && -n "$api_image" ]] || {
  echo "Build main isolated lab before HTTPS verification" >&2; exit 1;
}
docker tag "$schema_image" radius-stage3-ci-schema:latest
docker tag "$api_image" radius-stage3-ci-api:latest
export RADIUS_HTTPS_FIXTURE_DIR="$tmp/tls"
export RADIUS_HTTPS_PFX_PASSWORD
RADIUS_HTTPS_PFX_PASSWORD=$(python3 -c 'import secrets;print(secrets.token_urlsafe(36))')
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 1 \
  -keyout "$tmp/tls/server.key" -out "$tmp/tls/server.crt" \
  -subj "/CN=localhost" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
printf "%s" "$RADIUS_HTTPS_PFX_PASSWORD" > "$tmp/pfx-password"
openssl pkcs12 -export -out "$tmp/tls/server.pfx" \
  -inkey "$tmp/tls/server.key" -in "$tmp/tls/server.crt" \
  -passout "file:$tmp/pfx-password" >/dev/null 2>&1
chmod 644 "$tmp/tls/server.pfx" "$tmp/tls/server.crt"
chmod 600 "$tmp/tls/server.key" "$tmp/pfx-password"

docker compose -p "$project" -f "$compose_file" config --quiet
docker compose -p "$project" -f "$compose_file" up -d --wait
url="https://localhost:18443"
https() {
  curl --silent --show-error --cacert "$tmp/tls/server.crt" \
    --resolve "localhost:18443:127.0.0.1" "$@"
}
for i in $(seq 1 45); do
  if https --fail "$url/api/health/ready" >/dev/null 2>&1; then break; fi
  if (( i == 45 )); then
    echo "HTTPS Kestrel failed readiness" >&2; exit 1
  fi
  sleep 2
done
out="$tmp/response"
check() {
  local expected="$1"; shift
  local got
  got=$(https -o "$out" -w '%{http_code}' "$@")
  if [[ "$got" != "$expected" ]]; then
    echo "HTTPS acceptance: expected HTTP $expected, got $got" >&2
    exit 1
  fi
}
check 401 "$url/api/summary"
check 403 -H "Content-Type: application/json" -d '{}' "$url/api/admin/auth/login"
check 403 -H "Origin: https://untrusted.invalid" -H "Content-Type: application/json" \
  -d '{}' "$url/api/admin/auth/login"

# CI calls the SAME interactive first-admin bootstrap used by a human operator.
# No fixture backdoor, default password, or remote admin-seeding API exists.
export LAB_ADMIN_USER="test_$(python3 -c 'import secrets;print(secrets.token_hex(4))')"
export LAB_ADMIN_PASSWORD="A!b$(python3 -c 'import secrets;print(secrets.token_urlsafe(27))')9"
python3 - "$project" "$compose_file" <<'PY'
import os, pty, select, subprocess, sys, time
project, compose_file = sys.argv[1:]
master, slave = pty.openpty()
cmd = ["docker","compose","-p",project,"-f",compose_file,
       "run","--rm","-it","--entrypoint","dotnet","api",
       "RadiusManager.Api.dll","--bootstrap-admin"]
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                        close_fds=True, env={**os.environ, "TERM":"xterm"})
os.close(slave)
seen = b""
sent_user = sent_pass = False
deadline = time.monotonic() + 120
try:
    while time.monotonic() < deadline:
        ready,_,_=select.select([master],[],[],1)
        if ready:
            try: part=os.read(master,8192)
            except OSError: break
            if not part: break
            seen=(seen + part)[-15000:]
            if not sent_user and b"username" in seen.lower():
                os.write(master,os.environ["LAB_ADMIN_USER"].encode()+b"\r")
                sent_user=True
                seen=b""
            if sent_user and not sent_pass and b"password" in seen.lower():
                os.write(master,os.environ["LAB_ADMIN_PASSWORD"].encode()+b"\r")
                sent_pass=True
                seen=b""
        if proc.poll() is not None: break
    if proc.poll() is None:
        proc.kill()
        raise RuntimeError("bootstrap timeout")
    if proc.wait(timeout=5) != 0 or not(sent_user and sent_pass):
        raise RuntimeError("bootstrap failed")
except Exception as exc:
    print(f"Interactive CI bootstrap failed ({type(exc).__name__}); credentials not logged",file=sys.stderr)
    sys.exit(1)
finally:
    os.close(master)
PY

jar="$tmp/session.cookies"
fetch_csrf() {
  check 200 -b "$jar" -c "$jar" "$url/api/admin/auth/csrf"
  csrf=$(python3 - "$out" <<'PY'
import json,sys
value=json.load(open(sys.argv[1],encoding="utf-8"))["requestToken"]
assert isinstance(value,str) and len(value)>20
print(value)
PY
)
}
build_body() {
  python3 - "$tmp/payload.json" "$1" <<'PY'
import json,os,sys
path,kind=sys.argv[1:]
user=os.environ["LAB_ADMIN_USER"]
old=os.environ["LAB_ADMIN_PASSWORD"]
new=os.environ.get("LAB_ADMIN_PASSWORD_NEXT","")
if kind=="wrong": value={"username":user,"password":"incorrect-password"}
elif kind=="login": value={"username":user,"password":old}
elif kind=="next": value={"username":user,"password":new}
elif kind=="change": value={"currentPassword":old,"newPassword":new}
else: raise RuntimeError("invalid CI payload type")
with open(path,'w',encoding="utf-8") as f: json.dump(value,f)
PY
chmod 600 "$tmp/payload.json"
}
fetch_csrf
build_body wrong
check 401 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/login"
build_body login
check 200 -b "$jar" -c "$jar" -D "$tmp/login.headers" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/login"
grep -q "__Host-RadiusAdmin" "$jar"
python3 - "$tmp/login.headers" <<'PY'
from pathlib import Path
import sys
headers=Path(sys.argv[1]).read_text().lower()
cookies=[line for line in headers.splitlines() if "set-cookie:" in line and "__host-radiusadmin=" in line]
assert len(cookies)==1
assert all(x in cookies[0] for x in ("secure","httponly","samesite=strict"))
PY
check 200 -b "$jar" "$url/api/admin/auth/me"
grep -q "super-admin" "$out"
check 200 -b "$jar" "$url/api/summary"
check 403 -b "$jar" -H "Content-Type: application/json" \
  -d '{"name":"NoCsrf","downloadKbps":1024,"uploadKbps":256}' "$url/api/plans"

# Restart API; encrypted persisted Data Protection key ring must preserve cookie validity.
docker compose -p "$project" -f "$compose_file" restart api >/dev/null
for i in $(seq 1 30); do
  if https -b "$jar" --fail "$url/api/summary" >/dev/null 2>&1; then break; fi
  if (( i == 30 )); then
    echo "Valid session failed across HTTPS API restart" >&2; exit 1
  fi
  sleep 2
done

# Changing password must revoke all old sessions immediately.
fetch_csrf
export LAB_ADMIN_PASSWORD_NEXT="Z!n$(python3 -c 'import secrets;print(secrets.token_urlsafe(28))')8"
build_body change
cp "$jar" "$tmp/stale-after-change.cookies"
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" \
  "$url/api/admin/auth/change-password"
check 401 -b "$tmp/stale-after-change.cookies" "$url/api/summary"

# New password signs in; logout then must reject a stolen pre-logout cookie.
fetch_csrf
build_body next
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/login"
check 200 -b "$jar" "$url/api/summary"
cp "$jar" "$tmp/stale-after-logout.cookies"
fetch_csrf
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" -d '{}' "$url/api/admin/auth/logout"
check 401 -b "$tmp/stale-after-logout.cookies" "$url/api/summary"
echo "Isolated HTTPS login, Secure cookies, key persistence, RBAC, CSRF, password rotation and logout revocation PASS."
