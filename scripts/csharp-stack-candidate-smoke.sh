#!/usr/bin/env bash
# Exercise the actual API and daemon after C# schema installation in an independent project.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${CSHARP_STACK_TEST_ACK:-}" == isolated-ci ]] || {
  echo 'C# stack acceptance requires isolated CI' >&2; exit 1;
}
mode="${1:-fresh}"
[[ $# -le 1 && ( "$mode" == fresh || "$mode" == legacy-upgrade ) ]] || {
  echo 'Expected fresh or legacy-upgrade' >&2; exit 1;
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
# The upgrade variant begins with the original Python installer and normal
# services, using the same isolated project and database volume throughout.
if [[ "$mode" == legacy-upgrade ]]; then
  mounts=()
  for file in "$PWD"/database/[0-9][0-9][0-9]_*.sql; do
    mounts+=(-v "$file:/opt/radius/${file##*/}:ro")
  done
  [[ "${#mounts[@]}" == 20 ]]
  stack run --rm --no-deps "${mounts[@]}" --entrypoint /bin/bash radius /usr/local/bin/schema-init.sh
  [[ "$(sql -c "SELECT count(*) FROM app_schema_migrations WHERE engine_version='2.1.0'")" == 10 ]]
  stack up -d --no-deps radius api
else
  stack up -d radius api
fi
verify_initializer() {
[[ "$(stack ps -aq schema-init | wc -l)" == 1 ]]
init=$(stack ps -aq schema-init)
[[ "$(docker inspect --format '{{.State.ExitCode}}' "$init")" == 0 ]]
[[ "$(docker inspect --format '{{.Image}}' "$init")" == "$api_id" ]]
stack logs --no-color schema-init | grep -F 'C# migration execution PASS: 10 immutable versions'
}
if [[ "$mode" == fresh ]]; then verify_initializer; fi
for svc in db api radius; do
  case "$svc" in db) expected="$db_id";; api) expected="$api_id";; radius) expected="$radius_id";; esac
  [[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q "$svc")")" == "$expected" ]]
done
if [[ "$mode" == fresh ]]; then
  [[ "$(sql -c "SELECT count(*) FROM app_schema_migrations WHERE engine_version='3.0.0-csharp-lab'")" == 10 ]]
fi
wait_ready() {
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
}
wait_ready
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
# Compare complete ledger and fixture rows (including credential row, but
# only hash on the host, never print the rows or their values).
fingerprint() {
  sql -v name="$username" -v plan="$plan" -v session="$session" <<'SQL' | sha256sum | cut -d ' ' -f1
SELECT jsonb_build_array(
  (SELECT jsonb_agg(to_jsonb(m) ORDER BY version) FROM app_schema_migrations m),
  (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM app_plans p WHERE id=:'plan'::uuid),
  (SELECT jsonb_agg(to_jsonb(a) ORDER BY username) FROM app_lab_accounts a WHERE username=:'name'),
  (SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM radcheck c WHERE username=:'name'),
  (SELECT jsonb_agg(to_jsonb(g) ORDER BY id) FROM radusergroup g WHERE username=:'name'),
  (SELECT jsonb_agg(to_jsonb(r) ORDER BY radacctid) FROM radacct r WHERE username=:'name' AND acctsessionid=:'session')
);
SQL
}
ledger_before=$(sql -c "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")
before=$(fingerprint)
if [[ "$mode" == legacy-upgrade ]]; then
  # Stop application services before changing the initializer. DB stays
  # running on its original volume; never recreate or remove it.
  db_container_before=$(stack ps -q db)
  stack stop api radius
  stack up -d radius api
  verify_initializer
  [[ "$(stack ps -q db)" == "$db_container_before" ]]
  [[ "$(sql -c "SELECT count(*) FROM app_schema_migrations WHERE engine_version='2.1.0'")" == 10 ]]
  wait_ready
  [[ "$(fingerprint)" == "$before" ]]
  RADIUS_UI_URL="$url" bash scripts/ui-smoke.sh
  stack exec -T radius radtest "$username" "$password" 127.0.0.1 0 "$CSHARP_RADIUS_SECRET" >"$tmp/auth.log" 2>&1
  grep -q 'Access-Accept' "$tmp/auth.log"
  grep -q 'Mikrotik-Rate-Limit.*256k/1024k' "$tmp/auth.log"
  curl -fsS -u "$auth" "$url/api/lab-accounts" |
    python3 -c 'import json,sys; name=sys.argv[1]; assert any(row["username"]==name and row["active"] for row in json.load(sys.stdin))' "$username"
  echo 'Legacy Python to C# full-stack upgrade preserved ledger, credentials and accounting PASS'
fi
# Replay the candidate with existing data; no new version or voucher may appear.
stack run --rm --no-deps schema-init
[[ "$(fingerprint)" == "$before" ]]
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
