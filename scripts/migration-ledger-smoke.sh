#!/usr/bin/env bash
# Stage 02B: disposable CI database matrix, never use a customer or production DB.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$CI" == "true" && "$MIGRATION_TEST_ACK" == "isolated-lab" ]] || {
  echo 'Requires isolated GitHub CI plus MIGRATION_TEST_ACK=isolated-lab' >&2; exit 1;
}
umask 077
tmp=$(mktemp -d)
suffix=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
db_one="radius_mig_$suffix"
db_two="radius_mig_$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
db_partial="radius_mig_$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
cleanup() {
  for db in "$db_one" "$db_two" "$db_partial"; do
    [[ "$db" =~ ^radius_mig_[a-f0-9]{8}$ ]] || continue
    docker compose exec -T db dropdb -U radius --if-exists "$db" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

setup_database() {
  local db="$1"
  docker compose exec -T db createdb -U radius "$db"
  docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db" \
    --entrypoint bash schema-init -ec \
    'export PGPASSWORD="$DB_PASSWORD"; psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d "$MIGRATION_DB_NAME" -f /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql' >/dev/null
  docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -1 -U radius -d "$db" \
    -f /docker-entrypoint-initdb.d/001_app.sql >/dev/null
}
run_migration() {
  local db="$1"
  docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db" \
    -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
    schema-init /opt/radius/migrate.py
}
sql_count() {
  docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -tAc "$2" -U radius -d "$1" |
    tr -d '\r\n '
}
assert_count() {
  local actual
  actual=$(sql_count "$1" "$2")
  [[ "$actual" == "$3" ]] || {
    echo "Incorrect migration database test count: expected $3, got $actual" >&2; exit 1;
  }
}

# 1. Fresh DB, data preserved across transaction rollback and interrupted restart.
setup_database "$db_one"
plan_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -v plan_id="$plan_id" <<'SQL' >/dev/null
INSERT INTO app_plans (id,name,upload_kbps,download_kbps)
VALUES (:'plan_id'::uuid, 'preserved_migration_test',256,1024);
SQL
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=2 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail2.log" 2>&1; then
  echo "Version 2 failure injection was unexpectedly accepted" >&2; exit 1;
fi
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 1
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_lab_accounts'" 0
assert_count "$db_one" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1

if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=3 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail3.log" 2>&1; then
  echo "Version 3 interruption injection was unexpectedly accepted" >&2; exit 1;
fi
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 2
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_proc WHERE proname='app_lab_usage_snapshot'" 0
# Version 006 must roll back both table and index before its ledger entry.
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=6 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail6.log" 2>&1; then
  echo "Version 6 failure injection was unexpectedly accepted" >&2; exit 1;
fi
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 5
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_lab_account_owners'" 0
# Version 007 failure must roll back both the added column and the transfer table.
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=7 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail7.log" 2>&1; then
  echo "Version 7 failure injection was unexpectedly accepted" >&2; exit 1
fi
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 6
assert_count "$db_one" "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='app_lab_account_owners' AND column_name='ownership_version'" 0
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_lab_owner_transfers'" 0
# 008 rollback must leave no protection function or triggers and preserve prior data.
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=8 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail8.log" 2>&1; then
  echo "Version 8 failure injection was unexpectedly accepted" >&2; exit 1
fi
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 7
assert_count "$db_one" "SELECT count(*) FROM pg_proc WHERE proname='app_reject_audit_mutation'" 0
assert_count "$db_one" "SELECT count(*) FROM pg_trigger WHERE tgname IN ('audit_append_only','ownership_history_append_only')" 0
# Preserve an actual accounting row across 009 failure and retry.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" <<'SQL' >/dev/null
INSERT INTO radacct(acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctinputoctets,acctoutputoctets)
VALUES ('migration9','migration9-fixture','lab_000000000009','10.255.70.21',now(),100,200);
SQL
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=9 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail9.log" 2>&1; then
  echo "Version 9 failure injection was unexpectedly accepted" >&2; exit 1;
fi
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 8
assert_count "$db_one" "SELECT count(*) FROM pg_class WHERE relname IN ('idx_app_radacct_recent','idx_app_radacct_user_recent')" 0
assert_count "$db_one" "SELECT count(*) FROM radacct WHERE acctuniqueid='migration9-fixture' AND acctinputoctets=100 AND acctoutputoctets=200" 1
run_migration "$db_one" >"$tmp/restart.log" 2>&1
assert_count "$db_one" "SELECT count(*) FROM radacct WHERE acctuniqueid='migration9-fixture' AND acctinputoctets=100 AND acctoutputoctets=200" 1
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" < tests/accounting_indexes_verify.sql >/dev/null
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 9
assert_count "$db_one" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1
run_migration "$db_one" >"$tmp/replay.log" 2>&1
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 9
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
  -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
  schema-init /opt/radius/migrate.py --verify-only >"$tmp/verify.log" 2>&1

# A disabled guard must be treated as applied-schema drift.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c 'ALTER TABLE app_admin_audit_events DISABLE TRIGGER audit_append_only' >/dev/null
if run_migration "$db_one" >"$tmp/disabled-guard.log" 2>&1; then
  echo "Disabled audit guard was unexpectedly accepted" >&2; exit 1
fi
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c 'ALTER TABLE app_admin_audit_events ENABLE ALWAYS TRIGGER audit_append_only' >/dev/null
run_migration "$db_one" >"$tmp/guard-verified.log" 2>&1
# Same-name wrong-definition index is schema drift, not a valid migration.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c 'DROP INDEX public.idx_app_radacct_recent; CREATE INDEX idx_app_radacct_recent ON public.radacct(username)' >/dev/null
if run_migration "$db_one" >"$tmp/index-drift.log" 2>&1; then
  echo "Incorrect accounting index definition was accepted" >&2; exit 1;
fi
grep -q 'Accounting index definition or validity mismatch' "$tmp/index-drift.log"
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c 'DROP INDEX public.idx_app_radacct_recent; CREATE INDEX idx_app_radacct_recent ON public.radacct ((COALESCE(acctupdatetime,acctstarttime)) DESC,radacctid DESC)' >/dev/null
run_migration "$db_one" >"$tmp/index-verified.log" 2>&1
# 2. A deliberately corrupted SHA-256 checksum must fail closed.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c "UPDATE app_schema_migrations SET sha256=repeat('0',64) WHERE version=2" >/dev/null
if run_migration "$db_one" >"$tmp/drift.log" 2>&1; then
  echo "Corrupted migration checksum was accepted" >&2; exit 1;
fi
assert_count "$db_one" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1

# 3. Mixed-version legacy DB with already-created version 2 is adopted without replay.
setup_database "$db_two"
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_two" \
  --entrypoint bash schema-init -ec \
  'export PGPASSWORD="$DB_PASSWORD"; psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d "$MIGRATION_DB_NAME" -f /opt/radius/002_lab_accounts.sql' >/dev/null

# Two runners compete for the same advisory lock: both must see one valid ledger.
run_migration "$db_two" >"$tmp/concurrent1.log" 2>&1 &
first=$!
run_migration "$db_two" >"$tmp/concurrent2.log" 2>&1 &
second=$!
wait "$first"
wait "$second"
assert_count "$db_two" "SELECT count(*) FROM app_schema_migrations" 9
assert_count "$db_two" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_admin_sessions'" 1
assert_count "$db_two" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_admin_audit_events'" 1
assert_count "$db_two" "SELECT count(*) FROM app_schema_migrations WHERE filename LIKE '00%.sql'" 9

# 4. Verification-only mode cannot initialize schema or a migration ledger.
setup_database "$db_partial"
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_partial" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
     schema-init /opt/radius/migrate.py --verify-only >"$tmp/verify-empty.log" 2>&1; then
  echo "Verify-only unexpectedly created a baseline" >&2; exit 1;
fi
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_schema_migrations'" 0

# 5. Partial legacy objects must prevent even creating the ledger.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_partial" \
  -c 'CREATE TABLE app_nas_drafts (id uuid PRIMARY KEY)' >/dev/null
if run_migration "$db_partial" >"$tmp/partial.log" 2>&1; then
  echo "Partially created legacy objects incorrectly accepted" >&2; exit 1;
fi
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_schema_migrations'" 0
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_nas_drafts'" 1

echo 'Stage 02B PASS: fresh+populated, failure injection, restart, SHA-256 drift, mixed-version, concurrency, partial-schema refusal; all original fixture data preserved.'
