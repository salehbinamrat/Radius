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
cleanup() {
  local status=$?
  rm -f "$log"
  if ! docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' >/dev/null
DELETE FROM radacct WHERE username=:'username';
SQL
  then
    echo 'Synthetic accounting fixture cleanup failed' >&2
    if [[ "$status" == 0 ]]; then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT

send_accounting() {
 local status="$1" up="$2" down="$3" up_giga="${4:-}" down_giga="${5:-}"
 {
   printf 'User-Name = "%s"\n' "$username"
   printf 'Acct-Session-Id = "%s"\n' "$session_id"
   printf 'NAS-IP-Address = 10.255.70.21\n'
   printf 'NAS-Port = 5\n'
   printf 'Acct-Status-Type = %s\n' "$status"
   printf 'Acct-Input-Octets = %s\n' "$up"
   printf 'Acct-Output-Octets = %s\n' "$down"
   if [[ -n "$up_giga" ]]; then printf 'Acct-Input-Gigawords = %s\n' "$up_giga"; fi
   if [[ -n "$down_giga" ]]; then printf 'Acct-Output-Gigawords = %s\n' "$down_giga"; fi
   printf 'Acct-Session-Time = 60\n'
 } | docker compose exec -T radius radclient -x 127.0.0.1:1813 acct "$RADIUS_SECRET" > "$log" 2>&1 || {
   echo 'radclient accounting packet failed' >&2; exit 1;
 }
 grep -q 'Accounting-Response' "$log" || { echo 'No Accounting-Response' >&2; exit 1; }
}

assert_row() {
 local up="$1" down="$2" stopped="$3" result
 result=$(docker compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius \
   -v username="$username" -v session_id="$session_id" -v expected_up="$up" -v expected_down="$down" -v expected_stop="$stopped" <<'SQL'
SELECT CASE WHEN COUNT(*)=1 AND BOOL_AND(
                acctinputoctets = CAST(:'expected_up' AS bigint)
                AND acctoutputoctets = CAST(:'expected_down' AS bigint)
                AND (acctstoptime IS NOT NULL) = CAST(:'expected_stop' AS boolean)
       ) THEN 'ACCT_WIRE_OK' ELSE 'ACCT_WIRE_WRONG' END
FROM radacct WHERE username=:'username' AND acctsessionid=:'session_id';
SQL
 )
 [[ "$result" == ACCT_WIRE_OK ]] || { echo "Accounting snapshot mismatch: expected upload=$up download=$down stopped=$stopped" >&2; exit 1; }
}

# These are cumulative snapshots of one session, not extra debits.
send_accounting Start 0 0
send_accounting Interim-Update 100 200
assert_row 100 200 false
send_accounting Interim-Update 100 200
assert_row 100 200 false
send_accounting Stop 175 325
assert_row 175 325 true

echo 'Phase 3A FreeRADIUS accounting Start/Interim/Stop transport PASS'

# Independent session: RADIUS 32-bit octet counters roll over at 2^32.
# RFC 2869 Gigawords are the high words, not incremental debits.
session_id="wire_$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
send_accounting Start 0 0 0 0
send_accounting Interim-Update 4294967295 4294967295 0 0
assert_row 4294967295 4294967295 false
send_accounting Interim-Update 0 7 1 2
assert_row 4294967296 8589934599 false
# Duplicate cumulative snapshots must still produce one row and identical totals.
send_accounting Interim-Update 0 7 1 2
assert_row 4294967296 8589934599 false
send_accounting Stop 19 23 1 2
assert_row 4294967315 8589934615 true

# Both independent sessions must remain represented exactly once.
docker compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' | grep -qx ACCT_64BIT_SESSIONS_OK
SELECT CASE WHEN COUNT(*) = 2 AND COUNT(DISTINCT acctsessionid) = 2
                 AND BOOL_AND(acctstoptime IS NOT NULL)
            THEN 'ACCT_64BIT_SESSIONS_OK' ELSE 'ACCT_64BIT_SESSIONS_WRONG' END
FROM radacct WHERE username=:'username';
SQL
echo '64-bit RADIUS accounting rollover and repeated snapshot PASS (synthetic lab only)'
