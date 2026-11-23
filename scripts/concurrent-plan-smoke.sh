#!/usr/bin/env bash
# Test PostgreSQL unique-plan concurrency using only random, temporary laboratory data.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo "Run scripts/setup.sh first" >&2; exit 1; }
set -a; source .env; set +a
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API=http://127.0.0.1:8080/api
plan_name="stage1_race_$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
tempdir=$(mktemp -d)
cleanup() {
  rm -rf -- "$tempdir"
  docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v name="$plan_name" <<'SQL' >/dev/null || true
DELETE FROM radgroupreply r USING app_plans p
 WHERE p.name=:'name' AND r.groupname='plan-'||replace(p.id::text,'-','');
DELETE FROM app_plans WHERE name=:'name';
SQL
}
trap cleanup EXIT
payload=$(printf '{"name":"%s","downloadKbps":1024,"uploadKbps":256}' "$plan_name")
curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "Content-Type: application/json" --data "$payload" -o "$tempdir/a.json" -w "%{http_code}" "$API/plans" >"$tempdir/a.status" &
pid_a=$!
curl -sS -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "Content-Type: application/json" --data "$payload" -o "$tempdir/b.json" -w "%{http_code}" "$API/plans" >"$tempdir/b.status" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
a=$(cat "$tempdir/a.status"); b=$(cat "$tempdir/b.status")
if [[ ! ( "$a" == "201" && "$b" == "409" ) && ! ( "$a" == "409" && "$b" == "201" ) ]]; then
  echo "Concurrent plan insert outcomes were HTTP $a and $b, expected one 201 and one 409" >&2
  exit 1
fi
rows=$(docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tA -v name="$plan_name" <<'SQL'
SELECT count(*) FROM app_plans WHERE name=:'name';
SQL
)
[[ "$rows" == "1" ]] || { echo "Concurrent insert left $rows records (expected exactly one)" >&2; exit 1; }
echo "Stage 1 duplicate-plan concurrent create PASS"
