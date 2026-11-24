#!/usr/bin/env bash
# CI-only: test the isolated Compose service, without touching user records.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_RADIUS_STATUS_ACK:-}" == isolated-ci ]] || {
  echo 'Isolated CI acknowledgement required' >&2; exit 1;
}
# First verify a real packet exchange, then the Compose health state.
for i in $(seq 1 15); do
  if docker compose exec -T radius /usr/local/bin/radius-health-probe.sh; then break; fi
  if (( i == 15 )); then echo 'RADIUS Status-Server did not respond' >&2; exit 1; fi
  sleep 2
done
container_id=$(docker compose ps -q radius)
[[ -n "$container_id" ]] || exit 1
for i in $(seq 1 20); do
  if [[ "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" == healthy ]]; then break; fi
  if (( i == 20 )); then echo 'RADIUS health state did not become healthy' >&2; exit 1; fi
  sleep 2
done
# Derive a deliberately different secret only in the disposable subprocess.
# No server configuration, user records or running service are changed.
if docker compose exec -T radius bash -c '
  if [[ "$RADIUS_SECRET" == a* ]]; then first=b; else first=a; fi
  export RADIUS_SECRET="$first${RADIUS_SECRET:1}"
  exec /usr/local/bin/radius-health-probe.sh
'; then
  echo 'RADIUS probe accepted an incorrect secret' >&2
  exit 1
fi
docker compose exec -T radius /usr/local/bin/radius-health-probe.sh
# Confirm real publisher evidence crosses only the read-only mount.
set -a; source .env; set +a
umask 077
netrc=$(mktemp)
trap 'rm -f -- "$netrc"' EXIT
printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$netrc"
endpoint=http://127.0.0.1:8080/api/service-status/radius
[[ "$(curl --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' "$endpoint")" == 401 ]]
curl --fail --silent --show-error --max-time 5 --netrc-file "$netrc" "$endpoint" |
  python3 -c 'import json,sys; x=json.load(sys.stdin); assert set(x)=={"state","checkedAtUtc"} and x["state"]=="responsive" and x["checkedAtUtc"]'
echo 'FreeRADIUS Status-Server, Docker health, wrong-secret rejection and protected evidence endpoint PASS'
