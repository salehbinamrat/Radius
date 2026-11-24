#!/usr/bin/env bash
# CI-only, separately named database. Never seed or index the application DB.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${RADIUS_PERF_TEST_ACK:-}" == isolated-ci ]] || {
  echo 'Accounting performance test requires isolated CI' >&2; exit 1;
}
db="radius_mig_$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
created=0
cleanup() {
  if [[ "$created" == 1 && "$db" =~ ^radius_mig_[a-f0-9]{8}$ ]]; then
    docker compose exec -T db dropdb -U radius --if-exists "$db" >/dev/null
  fi
}
trap cleanup EXIT
docker compose exec -T db createdb -U radius "$db"
created=1
# Same official FreeRADIUS schema and immutable application migrations.
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db" \
  --entrypoint bash schema-init -ec '
    export PGPASSWORD="$DB_PASSWORD"
    psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d "$MIGRATION_DB_NAME" \
      -f /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql
  ' >/dev/null
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -1 -U radius -d "$db" \
  -f /docker-entrypoint-initdb.d/001_app.sql >/dev/null
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db" \
  -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
  schema-init /opt/radius/migrate.py
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db" \
  -e CI=true -e RADIUS_PERF_TEST_ACK=isolated-ci \
  -v "$PWD/tests/accounting_query_performance.py:/opt/radius/accounting-query-performance.py:ro" \
  -v "$PWD/src/RadiusManager.Api/LabSessionEndpoints.cs:/opt/radius/LabSessionEndpoints.cs:ro" \
  --entrypoint python3 schema-init /opt/radius/accounting-query-performance.py
echo 'Accounting query comparison completed; disposable DB removed on exit'
