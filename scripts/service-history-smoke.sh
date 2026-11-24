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
assert x["scope"]=="lab" and x["retention"]=="volume-snapshot"
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
# The isolated API can restart without losing the most recent persisted sample.
docker compose restart api >/dev/null
for i in $(seq 1 30); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:8080/api/health/ready >/dev/null; then break; fi
  if (( i == 30 )); then echo 'API restart readiness failed' >&2; exit 1; fi
  sleep 2
done
curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$url" |
  python3 -c '
import datetime,json,sys
x=json.load(sys.stdin)
assert x["retention"]=="volume-snapshot"
times=[datetime.datetime.fromisoformat(row["observedAtUtc"].replace("Z","+00:00")).timestamp() for row in x["samples"]]
assert any(abs(t-float(sys.argv[1])) < 0.000001 for t in times), "Previous sample lost after API restart"
' "$second"
alerts=http://127.0.0.1:8080/api/service-status/alerts
[[ "$(curl --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' "$alerts")" == 401 ]]
curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$alerts" |
  python3 -c '
import json,sys
x=json.load(sys.stdin)
assert set(x)=={"scope","window","confirmationCount","services","events"}
assert x["scope"]=="lab" and x["window"]=="retained-samples" and x["confirmationCount"]==2
assert {s["service"] for s in x["services"]}=={"postgresql","freeradius"}
assert all(s["state"] in {"healthy","pending","failed","unknown"} for s in x["services"])
assert len(x["events"])<=480
'
incidents=http://127.0.0.1:8080/api/service-status/incidents
[[ "$(curl --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' "$incidents")" == 401 ]]
curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$incidents" |
  python3 -c '
import json,sys
x=json.load(sys.stdin)
assert set(x)=={"scope","retention","closedCapacity","services","incidents"}
assert x["scope"]=="lab" and x["retention"]=="volume-snapshot" and x["closedCapacity"]==256
assert {s["service"] for s in x["services"]}=={"postgresql","freeradius"}
assert len(x["incidents"])<=258
'
echo 'Protected service observation history, restart recovery, alert projection and incident archive PASS'
