#!/usr/bin/env bash
# Phase 7A: API smoke. No production NAS, VPN or RouterOS calls are made.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo 'Run scripts/setup.sh first' >&2; exit 1; }
set -a; source .env; set +a
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API=http://127.0.0.1:8080/api
out=$(mktemp)
id=''
cleanup(){
  rm -f "$out"
  if [[ -n "$id" ]];then
    docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v draft="$id" <<'SQL' >/dev/null || true
DELETE FROM app_nas_draft_events WHERE draft_id=:'draft'::uuid;
DELETE FROM app_nas_drafts WHERE id=:'draft'::uuid;
SQL
  fi
}
trap cleanup EXIT
status=$(curl -sS -o "$out" -w '%{http_code}' "$API/nas-drafts")
[[ "$status" == 401 ]] || { echo "Unauthorized GET not blocked: $status" >&2;exit 1; }
for ip in '8.8.8.8' 'vpn.example.com' '10.1.02.3';do
  payload=$(printf '{"name":"Lab router","site":"Test site","vpnIp":"%s"}' "$ip")
  status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' -d "$payload" -o "$out" -w '%{http_code}' "$API/nas-drafts")
  [[ "$status" == 400 ]] || { echo "Unsafe address $ip accepted: $status" >&2;exit 1; }
done
name="lab-nas-$(python3 -c 'import secrets;print(secrets.token_hex(5))')"
before=$(docker compose exec -T db psql -X -U radius -d radius -tAc 'SELECT count(*) FROM nas' | tr -d '[:space:]')
payload=$(printf '{"name":"%s","site":"Isolated lab","vpnIp":"10.255.70.21"}' "$name")
status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' -d "$payload" -o "$out" -w '%{http_code}' "$API/nas-drafts")
[[ "$status" == 201 ]] || { cat "$out";echo "Draft create returned $status" >&2;exit 1; }
id=$(python3 - "$out" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));assert x['radiusClientEnabled'] is False and x['connectivityVerified'] is False
print(x['id'])
PY
)
status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' -d "$payload" -o "$out" -w '%{http_code}' "$API/nas-drafts")
[[ "$status" == 409 ]] || { echo "Duplicate NAS accepted: $status" >&2;exit 1; }
curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/nas-drafts" -o "$out"
python3 - "$out" "$id" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));found=[r for r in x['drafts'] if r['id']==sys.argv[2]]
assert len(found)==1 and found[0]['retired'] is False
assert found[0]['radiusClientEnabled'] is False and x['radiusRegistrationEnabled'] is False
assert not any('secret' in k.lower() or 'password' in k.lower() for k in found[0])
PY
# Browser requests from another origin must never retire an authenticated draft.
for header in 'Origin: https://attacker.example' 'Origin: null' 'Sec-Fetch-Site: cross-site'; do
  status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "$header" -X POST -o "$out" -w '%{http_code}' "$API/nas-drafts/$id/retire")
  [[ "$status" == 403 ]] || { echo "Cross-origin draft mutation not blocked ($header): $status" >&2;exit 1; }
done
status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -X POST -o "$out" -w '%{http_code}' "$API/nas-drafts/$id/retire")
[[ "$status" == 200 ]] || { echo "Retire returned $status" >&2;exit 1; }
curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/nas-drafts" -o "$out"
python3 - "$out" "$id" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));assert next(r for r in x['drafts'] if r['id']==sys.argv[2])['retired'] is True
PY
after=$(docker compose exec -T db psql -X -U radius -d radius -tAc 'SELECT count(*) FROM nas' | tr -d '[:space:]')
[[ "$before" == "$after" ]] || { echo 'Official FreeRADIUS NAS table changed unexpectedly' >&2;exit 1; }
echo 'NAS draft API authentication, validation, uniqueness, audit and isolation PASS'
