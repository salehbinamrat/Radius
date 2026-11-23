#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ ! -f .env ]]; then echo 'Run scripts/setup.sh first'; exit 1; fi
set -a; source .env; set +a
: "${RADIUS_SECRET:?}"
# Laboratory account only; never run this against a live production DB.
USER_NAME="lab_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
cleanup() {
  # A failed smoke test must not leave a working laboratory credential behind.
  docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$USER_NAME" <<'SQL' >/dev/null 2>&1 || true
DELETE FROM radcheck WHERE username=:'username';
SQL
}
trap cleanup EXIT
USER_PASS="$(python3 -c 'import secrets;print(secrets.token_hex(12))')"
# psql variables quoted with :'name' prevent SQL injection.
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U radius -d radius -v username="$USER_NAME" -v password="$USER_PASS" <<'SQL'
INSERT INTO radcheck (username,attribute,op,value)
VALUES (:'username','Cleartext-Password',':=',:'password');
SQL
echo 'Testing PAP authentication against the local RADIUS container...'
# radtest exists in the Debian freeradius-utils package.
docker compose exec -T radius radtest "$USER_NAME" "$USER_PASS" 127.0.0.1 0 "$RADIUS_SECRET" | tee /tmp/radius-lab-accept.txt
grep -q 'Access-Accept' /tmp/radius-lab-accept.txt
echo 'Testing negative authentication (wrong password)...'
if docker compose exec -T radius radtest "$USER_NAME" INVALID_PASSWORD 127.0.0.1 0 "$RADIUS_SECRET" 2>&1 | tee /tmp/radius-lab-reject.txt; then
  : # Some radtest versions exit 0 on an Access-Reject.
else
  : # Others exit nonzero; the Access-Reject response is checked below.
fi
grep -q 'Access-Reject' /tmp/radius-lab-reject.txt
echo 'Authentication smoke tests passed.'
# Cleanup runs on both success and failure via EXIT trap.
