#!/usr/bin/env bash
# End-to-end read-only lab session browsing. Never changes a production NAS.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo 'Run scripts/setup.sh first' >&2; exit 1; }
set -a; source .env; set +a
: "${RADIUS_SECRET:?}" "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API=http://127.0.0.1:8080/api
log=$(mktemp)
username='' plan_id='' outsider="other_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
cleanup(){
  rm -f "$log"
  if [[ -n "$username" ]]; then
    docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius \
      -v name="$username" -v outsider="$outsider" <<'SQL' >/dev/null || true
DELETE FROM radacct WHERE username IN (:'name',:'outsider');
DELETE FROM radcheck WHERE username=:'name';
DELETE FROM radusergroup WHERE username=:'name';
DELETE FROM app_lab_accounts WHERE username=:'name';
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
status=$(curl -sS -o "$log" -w '%{http_code}' "$API/lab-sessions")
[[ "$status" == 401 ]] || { echo "Session listing leaked to unauthenticated request: $status" >&2;exit 1; }
status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -o "$log" -w '%{http_code}' "$API/lab-sessions?state=invalid")
[[ "$status" == 400 ]] || { echo "Invalid state accepted: $status" >&2;exit 1; }
status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -o "$log" -w '%{http_code}' "$API/lab-sessions?username=normal-user")
[[ "$status" == 400 ]] || { echo "Non-lab username accepted: $status" >&2;exit 1; }
plan_name="lab_sessions_$(python3 -c 'import secrets;print(secrets.token_hex(5))')"
plan_json=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' \
 -d "{\"name\":\"$plan_name\",\"downloadKbps\":1024,\"uploadKbps\":256}" "$API/plans")
plan_id=$(printf '%s' "$plan_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
account_json=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' \
 -d "{\"planId\":\"$plan_id\"}" "$API/lab-accounts")
username=$(printf '%s' "$account_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')
[[ "$username" =~ ^lab_[a-f0-9]{12}$ ]] || { echo 'Lab username invalid' >&2;exit 1; }

send_packet(){
  local user="$1" stage="$2" in_octets="$3" out_octets="$4"
  {
    printf 'User-Name = "%s"\n' "$user"
    printf 'Acct-Session-Id = "%s"\n' "proof_$user"
    printf 'NAS-IP-Address = 10.255.70.21\n'
    printf 'NAS-Port = 7\n'
    printf 'Acct-Status-Type = %s\n' "$stage"
    printf 'Acct-Input-Octets = %s\n' "$in_octets"
    printf 'Acct-Output-Octets = %s\n' "$out_octets"
    printf 'Acct-Session-Time = 60\n'
  } | docker compose exec -T radius radclient -x 127.0.0.1:1813 acct "$RADIUS_SECRET" >"$log" 2>&1
  grep -q 'Accounting-Response' "$log" || { echo 'RADIUS Accounting-Response missing' >&2;exit 1; }
}
send_packet "$username" Start 0 0
send_packet "$username" Interim-Update 1536 4096
send_packet "$outsider" Start 0 0
send_packet "$outsider" Interim-Update 100 100
curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/lab-sessions?state=open&username=$username" | \
 python3 -c 'import sys,json; j=json.load(sys.stdin); assert len(j["sessions"])==1,j; s=j["sessions"][0]; assert s["uploadBytes"]==1536 and s["downloadBytes"]==4096,s; assert s["classification"]=="open-unconfirmed",s; assert j["billingVerified"] is False and j["connectivityVerified"] is False'
curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/lab-sessions?state=all" | \
 python3 -c 'import sys,json; j=json.load(sys.stdin); assert not any(x["username"].startswith("other_") for x in j["sessions"])'
send_packet "$username" Stop 2048 8192
curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/lab-sessions?state=closed&username=$username" | \
 python3 -c 'import sys,json; j=json.load(sys.stdin); assert len(j["sessions"])==1,j; s=j["sessions"][0]; assert s["classification"]=="closed" and s["uploadBytes"]==2048 and s["downloadBytes"]==8192,s'
curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/lab-sessions?state=open&username=$username" | \
 python3 -c 'import sys,json; j=json.load(sys.stdin); assert len(j["sessions"])==0,j'
echo 'Read-only laboratory session API: authorization, bounds, isolation, Start/Interim/Stop PASS'
