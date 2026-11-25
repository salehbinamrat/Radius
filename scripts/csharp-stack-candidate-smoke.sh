#!/usr/bin/env bash
# Exercise the actual API and daemon after C# schema installation in an independent project.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${CSHARP_STACK_TEST_ACK:-}" == isolated-ci ]] || {
  echo 'C# stack acceptance requires isolated CI' >&2; exit 1;
}
umask 077
tmp=$(mktemp -d)
export CSHARP_STACK_ID="radiuscsharp$(openssl rand -hex 4)"
[[ "$CSHARP_STACK_ID" =~ ^radiuscsharp[a-f0-9]{8}$ ]]
export CSHARP_DB_PASSWORD="$(openssl rand -hex 24)"
export CSHARP_ADMIN_PASSWORD="$(openssl rand -hex 24)"
export CSHARP_RADIUS_SECRET="$(openssl rand -hex 24)"
export CSHARP_OFFICIAL_SQL="$tmp/official.sql"
compose_file=tests/csharp-stack-candidate.compose.yaml
tags=()
stack_started=0
stack() { docker compose -p "$CSHARP_STACK_ID" -f "$compose_file" "$@"; }
cleanup() {
  local status=$?
  if [[ "$stack_started" == 1 ]]; then
    stack down -v --remove-orphans >/dev/null 2>&1 || status=1
  fi
  for tag in "${tags[@]}"; do docker image rm "$tag" >/dev/null 2>&1 || status=1; done
  rm -rf -- "$tmp"
  exit "$status"
}
trap cleanup EXIT
for svc in db api radius; do
  id=$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "$svc")")
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]]
  tag="radius-ci-$svc:$CSHARP_STACK_ID"
  docker tag "$id" "$tag"
  tags+=("$tag")
  case "$svc" in
    db) export CSHARP_DB_IMAGE="$tag"; db_id="$id";;
    api) export CSHARP_API_IMAGE="$tag"; api_id="$id";;
    radius) export CSHARP_RADIUS_IMAGE="$tag"; radius_id="$id";;
  esac
done
docker compose exec -T radius cat /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql >"$CSHARP_OFFICIAL_SQL"
test -s "$CSHARP_OFFICIAL_SQL"
chmod 644 "$CSHARP_OFFICIAL_SQL"
stack config --quiet
# Explicitly reject collisions before creating project-owned resources.
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$CSHARP_STACK_ID")" ]]
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$CSHARP_STACK_ID")" ]]
[[ -z "$(docker network ls -q --filter "label=com.docker.compose.project=$CSHARP_STACK_ID")" ]]
stack_started=1
stack up -d --wait db
sql() { stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"; }
# A normal database name alone must never authorize the candidate.
if stack run --rm --no-deps schema-init >"$tmp/unmarked.log" 2>&1; then
  echo 'Unmarked stack database accepted' >&2; exit 1
fi
grep -Fxq 'C# migration execution refused: Isolated stack database marker mismatch' "$tmp/unmarked.log"
[[ "$(sql -c "SELECT to_regclass('public.app_schema_migrations') IS NULL AND to_regclass('public.radcheck') IS NULL")" == t ]]
sql -v marker="radius-csharp-ci:$CSHARP_STACK_ID" <<'SQL'
COMMENT ON DATABASE radius IS :'marker';
SQL
stack up -d radius api
[[ "$(stack ps -aq schema-init | wc -l)" == 1 ]]
init=$(stack ps -aq schema-init)
[[ "$(docker inspect --format '{{.State.ExitCode}}' "$init")" == 0 ]]
[[ "$(docker inspect --format '{{.Image}}' "$init")" == "$api_id" ]]
stack logs --no-color schema-init | grep -F 'C# migration execution PASS: 10 immutable versions'
for svc in db api radius; do
  case "$svc" in db) expected="$db_id";; api) expected="$api_id";; radius) expected="$radius_id";; esac
  [[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q "$svc")")" == "$expected" ]]
done
[[ "$(sql -c "SELECT count(*) FROM app_schema_migrations WHERE engine_version='3.0.0-csharp-lab'")" == 10 ]]
addr=$(stack port api 8080)
[[ "$addr" =~ ^127\.0\.0\.1:[0-9]+$ ]]
url="http://$addr"
ready=0
for attempt in $(seq 1 30); do
  if curl --silent --fail "$url/api/health/ready" >/dev/null &&
     [[ "$(docker inspect --format '{{.State.Health.Status}}' "$(stack ps -q radius)")" == healthy ]]; then
    ready=1; break
  fi
  sleep 2
done
[[ "$ready" == 1 ]]
RADIUS_UI_URL="$url" bash scripts/ui-smoke.sh
auth="admin:$CSHARP_ADMIN_PASSWORD"
plan=$(curl -fsS -u "$auth" -H 'Content-Type: application/json' \
  --data '{"name":"csharp-stack-test","downloadKbps":1024,"uploadKbps":256}' "$url/api/plans" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
voucher=$(curl -fsS -u "$auth" -H 'Content-Type: application/json' \
  --data "$(printf '{"planId":"%s"}' "$plan")" "$url/api/lab-accounts")
username=$(printf '%s' "$voucher" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')
password=$(printf '%s' "$voucher" | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
[[ "$username" =~ ^lab_[a-f0-9]{12}$ && "$password" =~ ^[a-f0-9]{48}$ ]]
unset voucher
stack exec -T radius radtest "$username" "$password" 127.0.0.1 0 "$CSHARP_RADIUS_SECRET" >"$tmp/auth.log" 2>&1
grep -q 'Access-Accept' "$tmp/auth.log"
grep -q 'Mikrotik-Rate-Limit.*256k/1024k' "$tmp/auth.log"
session="csharp_$(openssl rand -hex 8)"
send_accounting() {
  {
    printf 'User-Name = "%s"\n' "$username"
    printf 'Acct-Session-Id = "%s"\n' "$session"
    printf 'NAS-IP-Address = 10.255.70.21\nNAS-Port = 5\n'
    printf 'Acct-Status-Type = %s\nAcct-Input-Octets = %s\nAcct-Output-Octets = %s\n' "$1" "$2" "$3"
    printf 'Acct-Session-Time = 60\n'
  } | stack exec -T radius radclient -x 127.0.0.1:1813 acct "$CSHARP_RADIUS_SECRET" >"$tmp/acct.log" 2>&1
  grep -q 'Accounting-Response' "$tmp/acct.log"
}
send_accounting Start 0 0
send_accounting Interim-Update 100 200
send_accounting Stop 175 325
[[ "$(sql -v name="$username" -v session="$session" <<'SQL'
SELECT count(*) FROM radacct WHERE username=:'name' AND acctsessionid=:'session'
  AND acctinputoctets=175 AND acctoutputoctets=325 AND acctstoptime IS NOT NULL;
SQL
)" == 1 ]]
# Replay the candidate with existing data; no new version or voucher may appear.
ledger_before=$(sql -c "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")
stack run --rm --no-deps schema-init
[[ "$(sql -c "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")" == "$ledger_before" ]]
[[ "$(sql -v name="$username" <<'SQL'
SELECT count(*) FROM app_lab_accounts WHERE username=:'name';
SQL
)" == 1 ]]
curl -fsS -u "$auth" -X POST "$url/api/lab-accounts/$username/disable" >/dev/null
if stack exec -T radius radtest "$username" "$password" 127.0.0.1 0 "$CSHARP_RADIUS_SECRET" >"$tmp/auth.log" 2>&1; then :; fi
grep -q 'Access-Reject' "$tmp/auth.log"
unset password auth
echo 'C# isolated full-stack startup, UI, API, PAP, accounting, replay and disable PASS'
