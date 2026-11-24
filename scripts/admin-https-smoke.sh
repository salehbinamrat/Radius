#!/usr/bin/env bash
# CI-only: independent PostgreSQL + TLS Kestrel + real admin cookie lifecycle.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(printenv CI || true)" == "true" && "$(printenv LAB_HTTPS_TEST_ACK || true)" == "isolated-ci" ]] || {
  echo "HTTPS acceptance requires isolated GitHub CI acknowledgement" >&2; exit 1;
}
[[ -f .env ]] || { echo "Isolated lab .env missing" >&2; exit 1; }
# The secondary Compose file lives under tests/. Export the existing isolated
# lab credentials explicitly so Compose does not search the wrong project dir.
set -a
source .env
set +a
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
RADIUS_HTTPS_PFX_PASSWORD=$(python3 -c 'import secrets;print(secrets.token_urlsafe(36))')
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 1 \
  -keyout "$tmp/server.key" -out "$tmp/tls/server.crt" \
  -subj "/CN=localhost" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
printf "%s" "$RADIUS_HTTPS_PFX_PASSWORD" > "$tmp/pfx-password"
openssl pkcs12 -export -out "$tmp/tls/server.pfx" \
  -inkey "$tmp/server.key" -in "$tmp/tls/server.crt" \
  -passout "file:$tmp/pfx-password" >/dev/null 2>&1
chmod 644 "$tmp/tls/server.pfx" "$tmp/tls/server.crt"
chmod 600 "$tmp/server.key" "$tmp/pfx-password"
# A separate encryption key is never used as the HTTPS server key.
dp_password=$(python3 -c 'import secrets;print(secrets.token_urlsafe(36))')
printf '%s' "$dp_password" > "$tmp/dp-password"
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 \
  -keyout "$tmp/dp.key" -out "$tmp/dp.crt" -subj "/CN=Radius CI Data Protection" \
  -addext "keyUsage=critical,keyEncipherment" >/dev/null 2>&1
openssl pkcs12 -export -out "$tmp/tls/data-protection.pfx" -inkey "$tmp/dp.key" \
  -in "$tmp/dp.crt" -passout "file:$tmp/dp-password" >/dev/null 2>&1
chmod 644 "$tmp/tls/data-protection.pfx"
unset dp_password
# Only the individual read-only files are mounted for the unprivileged API.
# The host directory is 0700; its contents are not traversable by other host users.
export RADIUS_HTTPS_SECRET_DIR="$tmp/secrets"
mkdir -m 700 "$RADIUS_HTTPS_SECRET_DIR"
printf '%s' "$DB_PASSWORD" > "$RADIUS_HTTPS_SECRET_DIR/db-password"
printf '%s' "$RADIUS_HTTPS_PFX_PASSWORD" > "$RADIUS_HTTPS_SECRET_DIR/tls-password"
cp "$tmp/dp-password" "$RADIUS_HTTPS_SECRET_DIR/dp-password"
chmod 444 "$RADIUS_HTTPS_SECRET_DIR/dp-password"
printf '%s' "$RADIUS_SECRET" > "$RADIUS_HTTPS_SECRET_DIR/radius-secret"
chmod 444 "$RADIUS_HTTPS_SECRET_DIR/db-password" "$RADIUS_HTTPS_SECRET_DIR/tls-password"
python3 - "$RADIUS_HTTPS_SECRET_DIR" <<'PY'
from pathlib import Path
import secrets,sys
root=Path(sys.argv[1])
for name in ("runtime-db-password","runtime-user-password","api-db-password","bootstrap-db-password"):
    (root/name).write_text(secrets.token_hex(24),encoding="ascii")
PY
chmod 400 "$RADIUS_HTTPS_SECRET_DIR/radius-secret" "$RADIUS_HTTPS_SECRET_DIR/runtime-db-password" "$RADIUS_HTTPS_SECRET_DIR/runtime-user-password"
chmod 444 "$RADIUS_HTTPS_SECRET_DIR/api-db-password" "$RADIUS_HTTPS_SECRET_DIR/bootstrap-db-password"
unset RADIUS_HTTPS_PFX_PASSWORD
# No database, Basic or PFX password should appear in the API container env.
docker compose -p "$project" -f "$compose_file" config --format json | python3 -c '
import json,sys
services=json.load(sys.stdin)["services"]
env=services["api"]["environment"]
assert "POSTGRES_PASSWORD" not in services["db"]["environment"]
assert services["db"]["environment"]["POSTGRES_PASSWORD_FILE"]=="/run/radius-secrets/db-password"
assert "DB_PASSWORD" not in services["schema-init"]["environment"]
assert services["schema-init"]["environment"]["DB_PASSWORD_FILE"]=="/run/radius-secrets/db-password"
assert "Password=" not in env["ConnectionStrings__RadiusDb"]
assert not {"RADIUS_ADMIN_PASSWORD","ASPNETCORE_Kestrel__Certificates__Default__Password","DB_PASSWORD"}.intersection(env)
assert env["RADIUS_DB_PASSWORD_FILE"]=="/run/radius-secrets/api-db-password"
assert env["ConnectionStrings__RadiusDb"].endswith("Username=radius_api")
assert all(v["target"] not in ("/run/radius-secrets/db-password","/run/radius-secrets/bootstrap-db-password","/run/radius-secrets/runtime-db-password")
           for v in services["api"]["volumes"])
assert env["RADIUS_TLS_PASSWORD_FILE"]=="/run/radius-secrets/tls-password"
assert env["RADIUS_DP_PASSWORD_FILE"]=="/run/radius-secrets/dp-password"
assert env["RADIUS_DP_CERTIFICATE_PATH"]=="/run/radius-tls/data-protection.pfx"
'

docker compose -p "$project" -f "$compose_file" config --quiet
# Complete schema initialization before creating the distinct login roles.
docker compose -p "$project" -f "$compose_file" up -d db schema-init
docker compose -p "$project" -f "$compose_file" wait schema-init
bash scripts/api-runtime-role-smoke.sh "$project" "$compose_file"
bash scripts/radius-runtime-role-smoke.sh "$project" "$compose_file"
docker compose -p "$project" -f "$compose_file" up -d --no-deps api
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
# Verify the running API really uses the restricted PostgreSQL login.
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius \
  -c "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='radius' AND usename='radius_api')" | grep -qx t
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
check 200 "$url/api/admin/auth/mode"
grep -q '"session"' "$out"
check 401 "$url/api/summary"
check 401 -H "Origin: $url" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
check 403 -H "Content-Type: application/json" -d '{}' "$url/api/admin/auth/login"
check 403 -H "Origin: https://untrusted.invalid" -H "Content-Type: application/json" \
  -d '{}' "$url/api/admin/auth/login"

# CI calls the SAME interactive first-admin bootstrap used by a human operator.
# No fixture backdoor, default password, or remote admin-seeding API exists.
export LAB_ADMIN_USER="test_$(python3 -c 'import secrets;print(secrets.token_hex(4))')"
export LAB_ADMIN_PASSWORD="A!b$(python3 -c 'import secrets;print(secrets.token_urlsafe(27))')9"
# Both independent PTYs reach password entry before either receives a password.
# Distinct usernames prevent a uniqueness index from masking a bootstrap race.
winner=$(python3 tests/concurrent_admin_bootstrap_smoke.py "$project" "$compose_file")
[[ "$winner" == primary || "$winner" == contender ]]
if [[ "$winner" == contender ]]; then export LAB_ADMIN_USER="${LAB_ADMIN_USER}_other"; fi
# Bootstrap is finished: disable its login and require zero surviving connections.
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius <<'SQL' | grep -qx BOOTSTRAP_DISABLED
ALTER ROLE radius_bootstrap NOLOGIN;
SELECT CASE WHEN NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname='radius_bootstrap')
 AND NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE usename='radius_bootstrap')
 THEN 'BOOTSTRAP_DISABLED' ELSE 'BOOTSTRAP_STILL_ACTIVE' END;
SQL
# Verify there is precisely one account and role assignment, and one atomic audit.
docker compose -p "$project" -f "$compose_file" exec -T db psql -U radius -d radius -At -v ON_ERROR_STOP=1 -c '
SELECT count(*) FROM "AspNetUsers";
SELECT count(*) FROM "AspNetUserRoles" WHERE "RoleId" = '\''role-super-admin'\'';
SELECT count(*) FROM app_admin_audit_events WHERE action = '\''bootstrap_admin'\'' AND outcome = '\''success'\'';
' | python3 -c 'import sys; assert sys.stdin.read().splitlines()==["1","1","1"]'

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
elif kind=="wrong-change": value={"currentPassword":"incorrect-password","newPassword":new}
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
check 403 -b "$jar" -H "Origin: https://untrusted.invalid" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
check 403 -b "$jar" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
check 200 -b "$jar" -H "Origin: $url" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
python3 - "$out" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert [t["transport"] for t in value["availableTransports"]] == ["WebSockets"]
assert value["connectionToken"]
PY
check 403 -b "$jar" -H "Content-Type: application/json" \
  -d '{"name":"NoCsrf","downloadKbps":1024,"uploadKbps":256}' "$url/api/plans"

# Replace HTTPS certificate and private key, but keep the Data Protection key.
# The authenticated jar predates the certificate change.
old_tls=$(openssl x509 -in "$tmp/tls/server.crt" -noout -fingerprint -sha256)
dp_before=$(sha256sum "$tmp/tls/data-protection.pfx" | cut -d ' ' -f1)
cp "$tmp/tls/server.crt" "$tmp/old-server.crt"
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 1 \
  -keyout "$tmp/renewed.key" -out "$tmp/renewed.crt" -subj "/CN=localhost" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
openssl pkcs12 -export -out "$tmp/tls/renewed.pfx" -inkey "$tmp/renewed.key" \
  -in "$tmp/renewed.crt" -passout "file:$tmp/pfx-password" >/dev/null 2>&1
chmod 644 "$tmp/tls/renewed.pfx" "$tmp/renewed.crt"
mv -f "$tmp/tls/renewed.pfx" "$tmp/tls/server.pfx"
mv -f "$tmp/renewed.crt" "$tmp/tls/server.crt"
new_tls=$(openssl x509 -in "$tmp/tls/server.crt" -noout -fingerprint -sha256)
[[ "$old_tls" != "$new_tls" && "$(sha256sum "$tmp/tls/data-protection.pfx" | cut -d ' ' -f1)" == "$dp_before" ]]
docker compose -p "$project" -f "$compose_file" restart api >/dev/null
for i in $(seq 1 30); do
  if https -b "$jar" --fail "$url/api/summary" >/dev/null 2>&1; then break; fi
  if (( i == 30 )); then
    echo "Valid session failed across HTTPS API restart" >&2; exit 1
  fi
  sleep 2
done

# An old trust anchor must fail; the new trusted certificate and original
# authenticated cookie already succeeded above. No insecure TLS bypass.
if curl --silent --max-time 5 --cacert "$tmp/old-server.crt" \
    --resolve "localhost:18443:127.0.0.1" "$url/api/health/ready" >/dev/null 2>&1; then
  echo "Old TLS trust anchor unexpectedly accepted renewed certificate" >&2; exit 1
fi
echo "TLS key renewal preserved authenticated session with independent Data Protection PASS"

# Change only role membership in this disposable DB, without rotating the security stamp.
# An existing stream must close even when the new role can itself read status.
cp "$jar" "$tmp/stale-after-role.cookies"
python3 tests/admin_role_change_wire_smoke.py "$tmp/tls/server.crt" "$jar" "$project" "$compose_file"
check 401 -b "$tmp/stale-after-role.cookies" "$url/api/summary"
check 401 -b "$tmp/stale-after-role.cookies" -H "Origin: $url" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
# Membership is restored by the fixture, but the observed stale cookie must remain revoked.
fetch_csrf
build_body login
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/login"
check 200 -b "$jar" "$url/api/admin/auth/me"
grep -q "super-admin" "$out"

# Changing password must revoke all old sessions immediately.
fetch_csrf
export LAB_ADMIN_PASSWORD_NEXT="Z!n$(python3 -c 'import secrets;print(secrets.token_urlsafe(28))')8"
# A failed current password must not change the session or record success.
build_body wrong-change
check 400 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/change-password"
check 200 -b "$jar" "$url/api/summary"
# Fingerprint only inside PostgreSQL/pipe, never print credential hashes or tokens.
password_state() {
  docker compose -p "$project" -f "$compose_file" exec -T db \
    psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius <<'SQL' | sha256sum | cut -d ' ' -f1
SELECT jsonb_build_array("Id","PasswordHash","SecurityStamp","ConcurrencyStamp") FROM "AspNetUsers" ORDER BY "Id";
SELECT jsonb_build_array(id,user_id,security_stamp,revoked_at) FROM app_admin_sessions ORDER BY id;
SELECT count(*) FROM app_admin_audit_events WHERE action='password_changed' AND outcome='success';
SQL
}
prior_password_state=$(password_state)
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius \
  -c "ALTER TABLE app_admin_audit_events ADD CONSTRAINT ci_reject_password_audit CHECK (action <> 'password_changed') NOT VALID" >/dev/null
build_body change
check 503 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/change-password"
[[ "$(password_state)" == "$prior_password_state" ]] || {
  echo 'Password state or session revocation changed despite failed audit' >&2; exit 1;
}
check 200 -b "$jar" "$url/api/summary"
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius \
  -c 'ALTER TABLE app_admin_audit_events DROP CONSTRAINT ci_reject_password_audit' >/dev/null
echo 'Password rotation rollback on forced audit failure PASS'
cp "$jar" "$tmp/stale-after-change.cookies"
# Two independent authenticated clients contend for the same change.
python3 tests/password_change_race_smoke.py "$tmp/tls/server.crt"
# Check revocation directly BEFORE attempting the old cookie, so lazy validation
# cannot mask a missing transactional revocation.
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -At -v ON_ERROR_STOP=1 -U radius -d radius <<'SQL' | python3 -c 'import sys; assert sys.stdin.read().splitlines()==["0","1","1"]'
SELECT count(*) FROM app_admin_sessions WHERE revoked_at IS NULL;
SELECT count(*) FROM app_admin_audit_events WHERE action='password_changed' AND outcome='success';
SELECT count(*) FROM app_admin_audit_events WHERE action='password_change_rejected' AND outcome='denied';
SQL
check 401 -b "$tmp/stale-after-change.cookies" "$url/api/summary"
# The original cookie was not the racing client; discard it locally only
# after demonstrating its server-side revocation.
rm -f "$jar"

# New password signs in; logout then must reject a stolen pre-logout cookie.
fetch_csrf
build_body next
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/login"
check 200 -b "$jar" "$url/api/summary"
cp "$jar" "$tmp/stale-after-logout.cookies"
# Verify the server contract independently before running Chromium.
python3 tests/signalr_https_wire_smoke.py "$tmp/tls/server.crt" "$jar"
check 401 -b "$tmp/stale-after-logout.cookies" "$url/api/summary"
check 401 -b "$tmp/stale-after-logout.cookies" -H "Origin: $url" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
echo "Isolated HTTPS login, Secure cookies, key persistence, RBAC, CSRF, password rotation and logout revocation PASS."
# A real mixed reseller/auditor session must not inherit shared lab or hub access.
# This database is the disposable HTTPS fixture only; no production role is changed.
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius <<'SQL' >/dev/null
UPDATE "AspNetUserRoles" SET "RoleId"='role-reseller' WHERE "RoleId"='role-super-admin';
INSERT INTO "AspNetUserRoles" ("UserId","RoleId")
SELECT "UserId",'role-auditor' FROM "AspNetUserRoles" WHERE "RoleId"='role-reseller';
SQL
jar="$tmp/reseller.cookies"
fetch_csrf
build_body next
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
  -H "Content-Type: application/json" --data-binary @"$tmp/payload.json" "$url/api/admin/auth/login"
check 200 -b "$jar" "$url/api/admin/auth/me"
python3 - "$out" <<'PY'
import json,sys
assert set(json.load(open(sys.argv[1]))["roles"])=={"reseller","auditor"}
PY
for path in summary plans lab-accounts lab-sessions service-status/incidents service-status/history nas-drafts; do
  check 403 -b "$jar" "$url/api/$path"
done
check 403 -b "$jar" -H "Origin: $url" -X POST "$url/hubs/lab-status/negotiate?negotiateVersion=1"
fetch_csrf
check 200 -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" -H "Content-Type: application/json" \
  -d '{}' "$url/api/admin/auth/logout"
docker compose -p "$project" -f "$compose_file" exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius <<'SQL' >/dev/null
DELETE FROM "AspNetUserRoles" WHERE "RoleId"='role-auditor';
UPDATE "AspNetUserRoles" SET "RoleId"='role-super-admin' WHERE "RoleId"='role-reseller';
SQL
echo "Isolated mixed reseller role denied shared HTTP and SignalR data PASS."
# Each independent acceptance phase starts with a fresh process-local rate
# budget, not a raised/bypassed production limit. Preserve database and key
# volumes; prove revocation survives these restarts.
restart_fixture_api() {
  docker compose -p "$project" -f "$compose_file" restart api >/dev/null
  for i in $(seq 1 30); do
    if https --fail "$url/api/health/ready" >/dev/null 2>&1; then
      check 401 -b "$tmp/stale-after-logout.cookies" "$url/api/summary"
      return 0
    fi
    if (( i == 30 )); then
      echo "HTTPS fixture API failed readiness after phase restart" >&2; return 1
    fi
    sleep 2
  done
}
restart_fixture_api
# Two distinct disposable identities prove row ownership at the SQL boundary.
python3 tests/reseller_scope_https_smoke.py "$tmp/tls/server.crt" "$project" "$compose_file"
restart_fixture_api
# A separate browser session signs in with the rotated password.
node tests/browser/https-live-status-smoke.mjs
# Restore the actual populated, disposable HTTPS database, not the Basic lab.
bash scripts/audit-recovery-smoke.sh "$project" "$compose_file"
