#!/usr/bin/env bash
# Only a disposable GitHub Actions lab; insert an inert unregistered RADIUS row.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true && "${LAB_SCOPE_ACK:-}" == isolated-ci ]] || exit 1
docker compose config --format json | python3 scripts/validate_lab_compose.py
set -a; source .env; set +a
umask 077
netrc=$(mktemp)
username="lab_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
inserted=0
cleanup(){
  if (( inserted )); then
    docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' >/dev/null || true
DELETE FROM radcheck WHERE username=:'username' AND attribute='Auth-Type' AND value='Reject';
SQL
  fi
  rm -f -- "$netrc"
}
trap cleanup EXIT
printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$netrc"
api=http://127.0.0.1:8080/api
get(){ curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$api/$1"; }
before=$(get summary)
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' >/dev/null
INSERT INTO radcheck(username,attribute,op,value)
SELECT :'username','Auth-Type',':=','Reject'
WHERE NOT EXISTS(SELECT 1 FROM app_lab_accounts WHERE username=:'username')
  AND NOT EXISTS(SELECT 1 FROM radcheck WHERE username=:'username');
SQL
inserted=1
# Assert the inert row exists and has no application ownership record.
docker compose exec -T db psql -X -At -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' | python3 -c 'import sys; assert sys.stdin.read().splitlines()==["1","0"]'
SELECT count(*) FROM radcheck WHERE username=:'username' AND attribute='Auth-Type' AND value='Reject';
SELECT count(*) FROM app_lab_accounts WHERE username=:'username';
SQL
after=$(get summary)
listing=$(get lab-accounts)
python3 - "$before" "$after" "$listing" "$username" <<'PY'
import json,sys
before,after,rows=map(json.loads,sys.argv[1:4])
assert before["labAccounts"]==after["labAccounts"], "Foreign RADIUS row leaked into summary"
assert all(row["username"]!=sys.argv[4] for row in rows)
PY
status=$(curl --silent --show-error --max-time 5 --netrc-file "$netrc" -o /dev/null -w '%{http_code}' "$api/lab-accounts/$username/usage")
[[ "$status" == 404 ]]
status=$(curl --silent --show-error --max-time 5 --netrc-file "$netrc" -o /dev/null -w '%{http_code}' -X POST "$api/lab-accounts/$username/disable")
[[ "$status" == 404 ]]
docker compose exec -T db psql -X -At -v ON_ERROR_STOP=1 -U radius -d radius -v username="$username" <<'SQL' | python3 -c 'import sys; assert sys.stdin.read().strip()=="1"'
SELECT count(*) FROM radcheck WHERE username=:'username' AND attribute='Auth-Type' AND value='Reject';
SQL
status=$(curl --silent --show-error --max-time 5 --netrc-file "$netrc" -o /dev/null -w '%{http_code}' "$api/ownership/resellers")
[[ "$status" == 403 ]]
status=$(curl --silent --show-error --max-time 5 --netrc-file "$netrc" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"ownerId":"invalid"}' "$api/ownership/accounts/$username/assign")
[[ "$status" == 403 ]]
echo 'Foreign RADIUS row excluded from summary, list, usage and disable; Basic ownership management denied PASS'
