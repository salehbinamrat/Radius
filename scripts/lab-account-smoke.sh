#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ ! -f .env ]]; then echo 'Run scripts/setup.sh first' >&2; exit 1; fi
set -a; source .env; set +a
: "${RADIUS_SECRET:?}" "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API=http://127.0.0.1:8080/api
LOG=$(mktemp)
plan_id='' username=''
cleanup() {
  rm -f "$LOG"
  if [[ -n "$username" ]]; then
    docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' >/dev/null || true
DELETE FROM radacct WHERE username=:'username';
DELETE FROM radcheck WHERE username=:'username';
DELETE FROM radusergroup WHERE username=:'username';
DELETE FROM app_lab_accounts WHERE username=:'username';
SQL
  fi
  if [[ -n "$plan_id" ]]; then
    docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v plan_id="$plan_id" <<'SQL' >/dev/null || true
DELETE FROM radgroupreply WHERE groupname='plan-'||replace(:'plan_id','-','');
DELETE FROM app_plans WHERE id=:'plan_id'::uuid;
SQL
  fi
}
trap cleanup EXIT
# A generated plan without quota / expiration is safe for this lab only.
plan_name="lab_phase2_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
plan_payload=$(printf '{"name":"%s","downloadKbps":1024,"uploadKbps":256}' "$plan_name")
plan_json=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d "$plan_payload" "$API/plans")
plan_id=$(printf '%s' "$plan_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
payload=$(printf '{"planId":"%s"}' "$plan_id")
response=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json'   -d "$payload" "$API/lab-accounts")
username=$(printf '%s' "$response" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')
password=$(printf '%s' "$response" | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
if [[ ! "$username" =~ ^lab_[a-f0-9]{12}$ || ! "$password" =~ ^[a-f0-9]{48}$ ]]; then
  echo 'Invalid generated lab credentials' >&2; exit 1
fi

# Avoid printing the temporary password into CI logs.
docker compose exec -T radius radtest "$username" "$password" 127.0.0.1 0 "$RADIUS_SECRET" >"$LOG" 2>&1 || true
if ! grep -q 'Access-Accept' "$LOG"; then
  echo 'Valid lab voucher was not accepted by FreeRADIUS' >&2; exit 1
fi
if ! grep -q 'Mikrotik-Rate-Limit.*256k/1024k' "$LOG"; then
  echo 'Plan group rate limit was not returned' >&2; exit 1
fi

# Negative test: wrong password must not authenticate.
docker compose exec -T radius radtest "$username" invalid_wrong_secret 127.0.0.1 0 "$RADIUS_SECRET" >"$LOG" 2>&1 || true
if ! grep -q 'Access-Reject' "$LOG"; then
  echo 'Wrong password was not rejected' >&2; exit 1
fi

# The admin listing must never echo the voucher password.
listing=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/lab-accounts")
if ! printf '%s' "$listing" | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert rows and all("password" not in row for row in rows)'; then
  echo 'Lab account list leaked a password or was empty' >&2; exit 1
fi

curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -X POST   "$API/lab-accounts/$username/disable" > /dev/null
# Disabled users cannot open a fresh session. Existing sessions are NOT disconnected.
docker compose exec -T radius radtest "$username" "$password" 127.0.0.1 0 "$RADIUS_SECRET" >"$LOG" 2>&1 || true
if ! grep -q 'Access-Reject' "$LOG"; then
  echo 'Disabled voucher still authenticates' >&2; exit 1
fi
# No administrative access without credentials.
status=$(curl -sS -o /dev/null -w '%{http_code}' "$API/lab-accounts")
if [[ "$status" != 401 ]]; then echo 'Lab API missing authentication' >&2; exit 1; fi
echo 'Phase 2 API + PAP/SQL group + disable integration PASS'
