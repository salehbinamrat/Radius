#!/usr/bin/env bash
# Explicit CI-only provisioning, no production migrations or role mutations.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci ]] || exit 1
[[ $# == 2 && "$1" =~ ^radiushttps[a-f0-9]{8}$ && "$2" == tests/admin-https.compose.yaml ]] || exit 1
project="$1"; compose_file="$2"
[[ -n "${RADIUS_HTTPS_SECRET_DIR:-}" ]] || exit 1
sql() {
  docker compose -p "$project" -f "$compose_file" exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"
}
# Send only a SCRAM verifier (and disposable PAP test credential) through stdin.
# Neither password appears in command arguments or logs. Fail closed on existing role.
if ! {
  python3 - "$RADIUS_HTTPS_SECRET_DIR" <<'PY'
from pathlib import Path
import base64, hashlib, hmac, re, secrets, sys
root=Path(sys.argv[1])
def read(name):
    value=(root/name).read_text(encoding="ascii")
    if not re.fullmatch(r"[a-f0-9]{48}",value):
        raise ValueError("Invalid fixture secret")
    return value
salt=secrets.token_bytes(16)
salted=hashlib.pbkdf2_hmac("sha256",read("runtime-db-password").encode(),salt,4096)
client=hmac.digest(salted,b"Client Key","sha256")
stored=hashlib.sha256(client).digest()
server=hmac.digest(salted,b"Server Key","sha256")
b64=lambda x:base64.b64encode(x).decode("ascii")
verifier=f"SCRAM-SHA-256$4096:{b64(salt)}${b64(stored)}:{b64(server)}"
print("BEGIN;")
print(f"CREATE ROLE radius_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '{verifier}';")
print("INSERT INTO public.radcheck(username,attribute,op,value) VALUES ('lab_00000000d2a1','Cleartext-Password',':=','" + read("runtime-user-password") + "');")
PY
  cat tests/radius_runtime_grants.sql
  printf 'COMMIT;\n'
} | sql >/dev/null 2>&1; then
  echo 'Disposable RADIUS runtime role provisioning failed' >&2; exit 1
fi
bash scripts/radius-file-secret-smoke.sh "$project" "$compose_file"
# Prove successful wire packets also wrote the expected database state.
sql <<'SQL' | grep -qx RUNTIME_WIRE_OK
SELECT CASE WHEN
 (SELECT count(*) FROM radacct WHERE username='lab_00000000d2a1'
   AND acctinputoctets=175 AND acctoutputoctets=325 AND acctstoptime IS NOT NULL)=1
 AND (SELECT count(*) FROM radacct WHERE username='lab_00000000d2a1')=1
 AND EXISTS (SELECT 1 FROM radpostauth WHERE username='lab_00000000d2a1' AND reply='Access-Accept')
THEN 'RUNTIME_WIRE_OK' ELSE 'RUNTIME_WIRE_FAILED' END;
SQL
# Only the owner cleans up the known disposable subscriber fixture.
sql <<'SQL' >/dev/null
DELETE FROM radacct WHERE username='lab_00000000d2a1';
DELETE FROM radpostauth WHERE username='lab_00000000d2a1';
DELETE FROM radcheck WHERE username='lab_00000000d2a1';
SQL
echo 'Restricted FreeRADIUS SQL role, PAP and accounting persistence PASS'
