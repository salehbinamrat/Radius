#!/usr/bin/env bash
# Isolated accounting transport test through FreeRADIUS (not a MikroTik device).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo 'Run scripts/setup.sh first' >&2; exit 1; }
set -a; source .env; set +a
: "${RADIUS_SECRET:?}"
username="lab_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
session_id="wire_$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

send_accounting() {
 local status="$1" up="$2" down="$3"
 {
   printf 'User-Name = "%s"\n' "$username"
   printf 'Acct-Session-Id = "%s"\n' "$session_id"
   printf 'NAS-IP-Address = 10.255.70.21\n'
   printf 'NAS-Port = 5\n'
   printf 'Acct-Status-Type = %s\n' "$status"
   printf 'Acct-Input-Octets = %s\n' "$up"
   printf 'Acct-Output-Octets = %s\n' "$down"
   printf 'Acct-Session-Time = 60\n'
 } | docker compose exec -T radius radclient -x 127.0.0.1:1813 acct "$RADIUS_SECRET" > "$log" 2>&1 || {
   echo 'radclient accounting packet failed' >&2; exit 1;
 }
 grep -q 'Accounting-Response' "$log" || { echo 'No Accounting-Response' >&2; exit 1; }
}

assert_row() {
 local up="$1" down="$2" stopped="$3"
 docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius \
   -v username="$username" -v expected_up="$up" -v expected_down="$down" -v expected_stop="$stopped" <<'SQL' | grep -q 'ACCT_WIRE_OK'
SELECT CASE WHEN COUNT(*)=1 AND BOOL_AND(
                acctinputoctets = CAST(:'expected_up' AS bigint)
                AND acctoutputoctets = CAST(:'expected_down' AS bigint)
                AND (acctstoptime IS NOT NULL) = CAST(:'expected_stop' AS boolean)
       ) THEN 'ACCT_WIRE_OK' ELSE 'ACCT_WIRE_WRONG' END
FROM radacct WHERE username=:'username';
SQL
}

# These are cumulative snapshots of one session, not extra debits.
send_accounting Start 0 0
send_accounting Interim-Update 100 200
assert_row 100 200 false
send_accounting Interim-Update 100 200
assert_row 100 200 false
send_accounting Stop 175 325
assert_row 175 325 true

docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' >/dev/null
DELETE FROM radacct WHERE username=:'username';
SQL
echo 'Phase 3A FreeRADIUS accounting Start/Interim/Stop transport PASS'
