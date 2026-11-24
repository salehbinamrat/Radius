#!/usr/bin/env bash
# Disposable CI only; create runtime and console enrollment logins before API starts.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci ]] || exit 1
[[ $# == 2 && "$1" =~ ^radiushttps[a-f0-9]{8}$ && "$2" == tests/admin-https.compose.yaml ]] || exit 1
[[ -n "${RADIUS_HTTPS_SECRET_DIR:-}" ]] || exit 1
project="$1"; compose_file="$2"
sql() {
  docker compose -p "$project" -f "$compose_file" exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"
}
if ! {
  python3 - "$RADIUS_HTTPS_SECRET_DIR" <<'PY'
import base64,hashlib,hmac,re,secrets,sys
from pathlib import Path
root=Path(sys.argv[1])
print("BEGIN;")
for role,file in (("radius_api","api-db-password"),("radius_bootstrap","bootstrap-db-password")):
    value=(root/file).read_text(encoding="ascii")
    if not re.fullmatch(r"[a-f0-9]{48}",value): raise ValueError("Invalid fixture secret")
    salt=secrets.token_bytes(16)
    salted=hashlib.pbkdf2_hmac("sha256",value.encode(),salt,4096)
    stored=hashlib.sha256(hmac.digest(salted,b"Client Key","sha256")).digest()
    server=hmac.digest(salted,b"Server Key","sha256")
    b64=lambda x:base64.b64encode(x).decode("ascii")
    verifier=f"SCRAM-SHA-256$4096:{b64(salt)}${b64(stored)}:{b64(server)}"
    print(f"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '{verifier}';")
PY
  cat tests/api_runtime_grants.sql
  printf 'COMMIT;\n'
} | sql >/dev/null 2>&1; then
  echo 'Disposable API role provisioning failed' >&2; exit 1
fi
# Use a distinct TCP login, not SET ROLE as the owner.
docker compose -p "$project" -f "$compose_file" run --rm --no-deps \
  --entrypoint python3 \
  -v "$RADIUS_HTTPS_SECRET_DIR/api-db-password:/run/radius-secrets/api-db-password:ro" \
  -v "$PWD/tests/api_runtime_role_probe.py:/opt/radius/api-runtime-role-probe.py:ro" \
  radius-runtime /opt/radius/api-runtime-role-probe.py
echo 'API and console enrollment roles provisioned independently PASS'
