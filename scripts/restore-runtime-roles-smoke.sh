#!/usr/bin/env bash
# Rebuild privileges on the fresh isolated restore only; never import cluster roles.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci && "${LAB_BACKUP_ACK:-}" == isolated-lab ]] || exit 1
[[ $# == 3 && "$1" =~ ^radiusrestore[a-f0-9]{8}$ && "$2" == tests/isolated-restore.compose.yaml && "$3" =~ ^[a-f0-9]{64}$ ]] || exit 1
project="$1"; compose_file="$2"; expected="$3"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
sql() {
  docker compose -p "$project" -f "$compose_file" exec -T restore-db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"
}
# Verify the archive did not carry role identities and that bootstrapping is not needed.
sql <<'SQL' | grep -qx ROLE_RESTORE_READY
SELECT CASE WHEN
    NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('radius_api','radius_runtime','radius_bootstrap'))
    AND (SELECT count(*) FROM "AspNetUserRoles" WHERE "RoleId"='role-super-admin')=1
THEN 'ROLE_RESTORE_READY' ELSE 'ROLE_RESTORE_REFUSED' END;
SQL
# Fresh disposable passwords; the bootstrap identity is created NOLOGIN from the start.
# No source credentials, global dump, password arguments, or password logs.
if ! {
  python3 - "$tmp" <<'PY'
import base64,hashlib,hmac,secrets,sys
from pathlib import Path
root=Path(sys.argv[1])
print("BEGIN;")
for role,file in (("radius_api","api-db-password"),("radius_runtime","runtime-db-password")):
    value=secrets.token_hex(24)
    (root/file).write_text(value,encoding="ascii")
    (root/file).chmod(0o400)
    salt=secrets.token_bytes(16)
    salted=hashlib.pbkdf2_hmac("sha256",value.encode(),salt,4096)
    stored=hashlib.sha256(hmac.digest(salted,b"Client Key","sha256")).digest()
    server=hmac.digest(salted,b"Server Key","sha256")
    b64=lambda x:base64.b64encode(x).decode("ascii")
    verifier=f"SCRAM-SHA-256$4096:{b64(salt)}${b64(stored)}:{b64(server)}"
    print(f"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '{verifier}';")
print("CREATE ROLE radius_bootstrap NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;")
PY
  cat tests/radius_runtime_grants.sql tests/api_runtime_grants.sql
  printf 'COMMIT;\n'
} | sql >/dev/null 2>&1; then
  echo 'Restored role provisioning failed' >&2; exit 1
fi
actual=$(sql < tests/runtime_role_fingerprint.sql | sha256sum | cut -d ' ' -f1)
[[ "$actual" == "$expected" ]] || {
  echo 'Restored role policy fingerprint mismatch' >&2; exit 1;
}
# Use the already-tested image on the restoration network, without any source
# password or owner mount. Reuse real positive/negative restricted TCP probes.
image=radius-stage3-ci-schema:latest
network="${project}_default"
docker run --rm --pull never --network "$network" \
  -e RADIUS_ROLE_PROBE_HOST=restore-db \
  -v "$tmp/api-db-password:/run/radius-secrets/api-db-password:ro" \
  -v "$PWD/tests/api_runtime_role_probe.py:/opt/radius/api-runtime-role-probe.py:ro" \
  --entrypoint python3 "$image" /opt/radius/api-runtime-role-probe.py
docker run --rm --pull never --network "$network" \
  -e RADIUS_ROLE_PROBE_HOST=restore-db -e RADIUS_DB_USER=radius_runtime \
  -e DB_PASSWORD_FILE=/run/radius-secrets/runtime-db-password \
  -v "$tmp/runtime-db-password:/run/radius-secrets/runtime-db-password:ro" \
  -v "$PWD/tests/radius_runtime_role_probe.py:/opt/radius/runtime-role-probe.py:ro" \
  --entrypoint python3 "$image" /opt/radius/runtime-role-probe.py
# Ensure the disabled enrollment login has no active connections or password.
sql <<'SQL' | grep -qx BOOTSTRAP_RESTORE_DISABLED
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_authid WHERE rolname='radius_bootstrap'
    AND NOT rolcanlogin AND rolpassword IS NULL)
    AND NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE usename='radius_bootstrap')
THEN 'BOOTSTRAP_RESTORE_DISABLED' ELSE 'BOOTSTRAP_RESTORE_UNSAFE' END;
SQL
echo 'Restored role policy fingerprint, fresh restricted TCP logins and disabled bootstrap PASS'
