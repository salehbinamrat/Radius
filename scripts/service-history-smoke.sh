#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_SERVICE_HISTORY_ACK:-}" == isolated-ci ]] || exit 1
set -a; source .env; set +a
umask 077
netrc=$(mktemp)
trap 'rm -f -- "$netrc"' EXIT
printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$netrc"
url=http://127.0.0.1:8080/api/service-status/history
[[ "$(curl --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' "$url")" == 401 ]]
# The first request must not create samples; the hosted service runs independently.
read_history() {
  curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$url" |
    python3 -c '
import datetime, json, sys
x=json.load(sys.stdin)
assert set(x)=={"scope","retention","intervalSeconds","capacity","samples"}
assert x["scope"]=="lab" and x["retention"]=="process-memory"
assert x["intervalSeconds"]==15 and x["capacity"]==240
assert 0 < len(x["samples"]) <= 240
for row in x["samples"]:
    assert set(row)=={"observedAtUtc","database","databaseCheckMs","radius","radiusCheckedAtUtc"}
    assert row["database"] in {"reachable","no-response","unknown"}
    assert row["radius"] in {"responsive","no-response","unknown"}
    assert row["databaseCheckMs"] is None or 0 <= row["databaseCheckMs"] <= 10000
last=x["samples"][-1]
assert last["database"]=="reachable"
print(datetime.datetime.fromisoformat(last["observedAtUtc"].replace("Z","+00:00")).timestamp())
'
}
first=$(read_history)
# Wait for a new independent observation without making any requests to the API.
sleep 17
second=$(read_history)
python3 - "$first" "$second" <<'PY'
import sys
assert float(sys.argv[2]) > float(sys.argv[1]), "No independent observation"
PY
echo 'Protected bounded independent service observation history PASS'
