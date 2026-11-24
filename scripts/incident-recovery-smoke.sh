#!/usr/bin/env bash
# Destructive to availability ONLY inside the disposable GitHub Actions lab.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true && "${LAB_INCIDENT_FAILURE_ACK:-}" == isolated-ci ]] || {
  echo 'Isolated GitHub Actions acknowledgement required' >&2; exit 1;
}
# Require the known loopback-only lab configuration before stopping anything.
docker compose config --format json | python3 scripts/validate_lab_compose.py
set -a; source .env; set +a
umask 077
netrc=$(mktemp)
stopped=0
cleanup() {
  if (( stopped )); then docker compose start db >/dev/null || true; fi
  rm -f -- "$netrc"
}
trap cleanup EXIT
printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$netrc"
url=http://127.0.0.1:8080/api/service-status/incidents
read_archive() {
  curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$url"
}
check_archive() {
  local mode=$1 id=${2:-}
  read_archive | python3 -c '
import json,sys
x=json.load(sys.stdin)
assert x["retention"]=="volume-snapshot"
rows=[r for r in x["incidents"] if r["service"]=="postgresql"]
state=next(s["state"] for s in x["services"] if s["service"]=="postgresql")
mode,ident=sys.argv[1:]
opened=[r for r in rows if r["recoveryConfirmedAtUtc"] is None]
if mode=="healthy":
    assert state=="healthy" and not opened
elif mode=="open":
    assert state=="failed" and len(opened)==1
    print(opened[0]["id"])
elif mode=="same":
    assert len(opened)==1 and opened[0]["id"]==ident
elif mode=="closed":
    match=[r for r in rows if r["id"]==ident]
    assert state=="healthy" and not opened and len(match)==1 and match[0]["recoveryConfirmedAtUtc"]
' "$mode" "$id"
}
wait_archive() {
  local mode=$1 id=${2:-} result
  for i in $(seq 1 30); do
    if result=$(check_archive "$mode" "$id" 2>/dev/null); then printf '%s\n' "$result"; return 0; fi
    sleep 3
  done
  echo "Incident acceptance timed out: $mode" >&2
  return 1
}
wait_archive healthy >/dev/null
stopped=1
docker compose stop db >/dev/null
incident=$(wait_archive open)
[[ -n "$incident" ]]
# Keep PostgreSQL stopped; verify persisted identity through an API process restart.
docker compose restart api >/dev/null
wait_archive same "$incident" >/dev/null
docker compose start db >/dev/null
for i in $(seq 1 30); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:8080/api/health/ready >/dev/null; then break; fi
  if (( i == 30 )); then echo 'PostgreSQL recovery readiness failed' >&2; exit 1; fi
  sleep 3
done
wait_archive closed "$incident" >/dev/null
stopped=0
echo 'Isolated PostgreSQL confirmed incident, stable identity after API restart, and confirmed recovery PASS'
