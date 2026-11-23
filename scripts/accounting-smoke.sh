#!/usr/bin/env bash
# Test-only SQL fixture for the canonical radacct snapshot across two NASes.
# This exercises the report, NOT actual RouterOS accounting or quota enforcement.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo 'Run scripts/setup.sh first' >&2; exit 1; }
set -a; source .env; set +a
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API=http://127.0.0.1:8080/api
plan_id='' username=''
cleanup() {
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
plan_json=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Accounting lab $(date +%s)-$$\",\"downloadKbps\":1024,\"uploadKbps\":256}" "$API/plans")
plan_id=$(printf '%s' "$plan_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
account_json=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d "{\"planId\":\"$plan_id\"}" "$API/lab-accounts")
username=$(printf '%s' "$account_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')
[[ "$username" =~ ^lab_[a-f0-9]{12}$ ]] || { echo 'Invalid lab username' >&2; exit 1; }

# Two separate NAS addresses + two unique sessions. A row stores cumulative,
# not incremental counters; a repeated Interim-Update updates the same row.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL'
INSERT INTO radacct
  (acctsessionid, acctuniqueid, username, nasipaddress,
   acctstarttime, acctupdatetime, acctstoptime, acctinputoctets, acctoutputoctets)
VALUES
  ('acct-1', md5(:'username' || '-nas1'), :'username', '10.255.70.10'::inet,
   now()-interval '2 minutes', now()-interval '1 minute', now()-interval '1 minute', 1000, 3000),
  ('acct-2', md5(:'username' || '-nas2'), :'username', '10.255.70.11'::inet,
   now()-interval '1 minute', now(), NULL, 3, 7);
SQL

verify() {
  local expected_open="$1" expected_up="$2" expected_down="$3" expected_anomalies="$4" expected_final="$5"
  local response
  response=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/lab-accounts/$username/usage")
  printf '%s' "$response" | python3 -c '
import json,sys
r=json.load(sys.stdin)
up, down, active, anomalies, final=(int(x) for x in sys.argv[1:6])
assert int(r["uploadBytes"]) == up, r
assert int(r["downloadBytes"]) == down, r
assert int(r["totalBytes"]) == up+down, r
assert r["sessions"]==2 and r["observedNas"]==2, r
assert r["openSessions"]==active and r["staleSessions"]==0, r
assert r["anomalousSessions"]==anomalies, r
assert r["reportIsFinal"] == bool(final), r
assert r["billingVerified"] is False and r["quotaEnforced"] is False, r
' "$expected_up" "$expected_down" "$expected_open" "$expected_anomalies" "$expected_final"
}
verify 1 1003 3007 0 0
# Repeating a cumulative interim snapshot must not add the same bytes twice.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL'
UPDATE radacct SET acctinputoctets=3, acctoutputoctets=7, acctupdatetime=now()
 WHERE username=:'username' AND acctsessionid='acct-2';
SQL
verify 1 1003 3007 0 0
# Once both sessions are stopped, the snapshot is closed, NOT billing-certified.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL'
UPDATE radacct SET acctstoptime=now() WHERE username=:'username' AND acctsessionid='acct-2';
SQL
verify 0 1003 3007 0 1
# Invalid negative device counters must flag an anomaly, not produce negative usage.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL'
UPDATE radacct SET acctinputoctets=-1 WHERE username=:'username' AND acctsessionid='acct-2';
SQL
verify 0 1000 3007 1 0

code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/lab-accounts/$username/usage")
[[ "$code" == 401 ]] || { echo 'Accounting endpoint missing auth' >&2; exit 1; }
code=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -o /dev/null -w '%{http_code}' "$API/lab-accounts/invalid/usage")
[[ "$code" == 400 ]] || { echo 'Invalid username accepted' >&2; exit 1; }
code=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -o /dev/null -w '%{http_code}' "$API/lab-accounts/lab_000000000000/usage")
[[ "$code" == 404 ]] || { echo 'Nonexistent username accepted' >&2; exit 1; }

echo 'Phase 3A cumulative accounting from two NASes PASS (report-only)'
