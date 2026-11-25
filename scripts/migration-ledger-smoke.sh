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
db_csharp="radius_mig_$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
db_csharp_legacy="radius_mig_$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
cleanup() {
  for db in "$db_one" "$db_two" "$db_partial" "$db_csharp" "$db_csharp_legacy"; do
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
# Candidate runs in the built API image, only against disposable fixtures.
verify_csharp() {
  local db="$1"
  docker compose run --rm --no-deps -e CI=true -e LAB_MIGRATION_TEST_MODE=isolated-ci \
    -e MIGRATION_DB_NAME="$db" -v "$PWD/database:/opt/radius:ro" \
    --entrypoint dotnet api /app/RadiusManager.Api.dll --migration-verify /opt/radius
}
assert_csharp_refusal() {
  local db="$1" marker="$2"
  if verify_csharp "$db" >"$tmp/csharp-refusal.log" 2>&1; then
    echo 'C# candidate unexpectedly accepted invalid migration state' >&2; exit 1
  fi
  grep -Fxq "C# migration verification refused: $marker" "$tmp/csharp-refusal.log" || {
    echo 'C# candidate refusal did not match expected reason' >&2; exit 1;
  }
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

# Failure must occur at the requested transaction, not at an earlier guard or SQL error.
# Only print known-safe diagnostics; temporary raw logs remain private and are removed.
assert_injected_failure() {
  local version="$1" log="$2"
  if ! grep -Fxq "Database migration refused: CI failure injection after version $version SQL; transaction rolled back" "$log"; then
    echo "Expected post-SQL rollback marker missing for migration $version" >&2
    grep -Ex 'Database migration refused: (Migration failure injection requires an isolated CI database|SQLSTATE [A-Z0-9]{5}|SQLSTATE unclassified)' "$log" >&2 || true
    exit 1
  fi
  echo "Verified injected rollback after migration $version SQL"
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
assert_injected_failure 2 "$tmp/fail2.log"
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 1
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_lab_accounts'" 0
assert_count "$db_one" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1

if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=3 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail3.log" 2>&1; then
  echo "Version 3 interruption injection was unexpectedly accepted" >&2; exit 1;
fi
assert_injected_failure 3 "$tmp/fail3.log"
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 2
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_proc WHERE proname='app_lab_usage_snapshot'" 0
# Version 006 must roll back both table and index before its ledger entry.
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=6 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail6.log" 2>&1; then
  echo "Version 6 failure injection was unexpectedly accepted" >&2; exit 1;
fi
assert_injected_failure 6 "$tmp/fail6.log"
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 5
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_lab_account_owners'" 0
# Version 007 failure must roll back both the added column and the transfer table.
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=7 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail7.log" 2>&1; then
  echo "Version 7 failure injection was unexpectedly accepted" >&2; exit 1
fi
assert_injected_failure 7 "$tmp/fail7.log"
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 6
assert_count "$db_one" "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='app_lab_account_owners' AND column_name='ownership_version'" 0
assert_count "$db_one" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_lab_owner_transfers'" 0
# 008 rollback must leave no protection function or triggers and preserve prior data.
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=8 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail8.log" 2>&1; then
  echo "Version 8 failure injection was unexpectedly accepted" >&2; exit 1
fi
assert_injected_failure 8 "$tmp/fail8.log"
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
assert_injected_failure 9 "$tmp/fail9.log"
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 8
assert_count "$db_one" "SELECT count(*) FROM pg_class WHERE relname IN ('idx_app_radacct_recent','idx_app_radacct_user_recent')" 0
assert_count "$db_one" "SELECT count(*) FROM radacct WHERE acctuniqueid='migration9-fixture' AND acctinputoctets=100 AND acctoutputoctets=200" 1
# A failed 010 must leave the original function and ledger unchanged.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" <<'SQL' >/dev/null
INSERT INTO radacct(acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctstoptime,acctinputoctets,acctoutputoctets)
VALUES ('migration10','migration10-fixture','lab_000000000010','10.255.70.21',now(),now(),NULL,NULL);
SQL
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci -e MIGRATION_FAIL_AFTER_SQL_VERSION=10 \
     --entrypoint python3 schema-init /opt/radius/migrate.py >"$tmp/fail10.log" 2>&1; then
  echo "Version 10 failure injection was unexpectedly accepted" >&2; exit 1;
fi
assert_injected_failure 10 "$tmp/fail10.log"
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 9
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations WHERE version=9 AND filename='009_accounting_read_indexes.sql'" 1
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" < tests/accounting_indexes_verify.sql >/dev/null
assert_count "$db_one" "SELECT count(*) FROM pg_proc WHERE proname='app_accounting_row_anomalous'" 0
assert_count "$db_one" "SELECT anomalous_sessions FROM app_lab_usage_snapshot('lab_000000000010')" 0
run_migration "$db_one" >"$tmp/restart.log" 2>&1
assert_count "$db_one" "SELECT anomalous_sessions FROM app_lab_usage_snapshot('lab_000000000010')" 1
assert_count "$db_one" "SELECT count(*) FROM radacct WHERE acctuniqueid='migration10-fixture' AND acctinputoctets IS NULL AND acctoutputoctets IS NULL" 1
assert_count "$db_one" "SELECT count(*) FROM radacct WHERE acctuniqueid='migration9-fixture' AND acctinputoctets=100 AND acctoutputoctets=200" 1
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" < tests/accounting_indexes_verify.sql >/dev/null
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 10
assert_count "$db_one" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1
run_migration "$db_one" >"$tmp/replay.log" 2>&1
assert_count "$db_one" "SELECT count(*) FROM app_schema_migrations" 10
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_one" \
  -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
  schema-init /opt/radius/migrate.py --verify-only >"$tmp/verify.log" 2>&1

# Verify legacy-installed schema without modifying ledger or fixture data.
before_ledger=$(sql_count "$db_one" "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")
verify_csharp "$db_one"
[[ "$(sql_count "$db_one" "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")" == "$before_ledger" ]]
assert_count "$db_one" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1

# A disabled guard must be treated as applied-schema drift.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c 'ALTER TABLE app_admin_audit_events DISABLE TRIGGER audit_append_only' >/dev/null
if run_migration "$db_one" >"$tmp/disabled-guard.log" 2>&1; then
  echo "Disabled audit guard was unexpectedly accepted" >&2; exit 1
fi
assert_csharp_refusal "$db_one" 'Applied migration 8 has missing/partial objects'
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
assert_csharp_refusal "$db_one" 'Accounting index definition or validity mismatch'
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c 'DROP INDEX public.idx_app_radacct_recent; CREATE INDEX idx_app_radacct_recent ON public.radacct ((COALESCE(acctupdatetime,acctstarttime)) DESC,radacctid DESC)' >/dev/null
run_migration "$db_one" >"$tmp/index-verified.log" 2>&1
# 2. A deliberately corrupted SHA-256 checksum must fail closed.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_one" \
  -c "UPDATE app_schema_migrations SET sha256=repeat('0',64) WHERE version=2" >/dev/null
if run_migration "$db_one" >"$tmp/drift.log" 2>&1; then
  echo "Corrupted migration checksum was accepted" >&2; exit 1;
fi
assert_csharp_refusal "$db_one" 'Migration checksum/filename mismatch'
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
assert_count "$db_two" "SELECT count(*) FROM app_schema_migrations" 10
assert_count "$db_two" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_admin_sessions'" 1
assert_count "$db_two" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_admin_audit_events'" 1
assert_count "$db_two" "SELECT count(*) FROM app_schema_migrations WHERE filename LIKE '00%.sql'" 9
assert_count "$db_two" "SELECT count(*) FROM app_schema_migrations WHERE filename='010_accounting_quality.sql'" 1

# 4. Verification-only mode cannot initialize schema or a migration ledger.
setup_database "$db_partial"
if docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_partial" \
     -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
     schema-init /opt/radius/migrate.py --verify-only >"$tmp/verify-empty.log" 2>&1; then
  echo "Verify-only unexpectedly created a baseline" >&2; exit 1;
fi
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_schema_migrations'" 0

assert_csharp_refusal "$db_partial" 'Migration ledger missing; verify-only cannot create schema'
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_schema_migrations'" 0
verify_csharp "$db_two"
echo 'C# read-only migration verifier parity PASS (isolated fixtures)'

# 5. Partial legacy objects must prevent even creating the ledger.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_partial" \
  -c 'CREATE TABLE app_nas_drafts (id uuid PRIMARY KEY)' >/dev/null
if run_migration "$db_partial" >"$tmp/partial.log" 2>&1; then
  echo "Partially created legacy objects incorrectly accepted" >&2; exit 1;
fi
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_schema_migrations'" 0
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_nas_drafts'" 1

# Candidate executor: preserve the current Python installation path while
# proving the same transaction, restart, legacy-adoption and lock contracts.
apply_csharp() {
  local db="$1" injection="${2:-}"
  docker compose run --rm --no-deps -e CI=true -e LAB_MIGRATION_TEST_MODE=isolated-ci \
    -e MIGRATION_DB_NAME="$db" -e MIGRATION_FAIL_AFTER_SQL_VERSION="$injection" \
    -v "$PWD/database:/opt/radius:ro" --entrypoint dotnet api \
    /app/RadiusManager.Api.dll --migration-apply-candidate /opt/radius
}
setup_database "$db_csharp"
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d "$db_csharp" \
  -v plan_id="$plan_id" <<'SQL' >/dev/null
INSERT INTO app_plans (id,name,upload_kbps,download_kbps)
VALUES (:'plan_id'::uuid, 'preserved_csharp_migration_test',256,1024);
SQL
for version in 2 3 4 6 7 8 9 10; do
  if apply_csharp "$db_csharp" "$version" >"$tmp/csharp-injected.log" 2>&1; then
    echo "C# failure injection unexpectedly accepted: $version" >&2; exit 1
  fi
  grep -Fxq "C# migration execution refused: CI failure injection after version $version SQL; transaction rolled back" "$tmp/csharp-injected.log"
  assert_count "$db_csharp" "SELECT count(*) FROM app_schema_migrations" "$((version-1))"
  assert_count "$db_csharp" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1
done
assert_count "$db_csharp" "SELECT count(*) FROM pg_proc WHERE proname='app_accounting_row_anomalous'" 0
apply_csharp "$db_csharp"
assert_count "$db_csharp" "SELECT count(*) FROM app_schema_migrations WHERE engine_version='3.0.0-csharp-lab'" 10
verify_csharp "$db_csharp"
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_csharp" \
  -e LAB_MIGRATION_TEST_MODE=isolated-ci --entrypoint python3 \
  schema-init /opt/radius/migrate.py --verify-only
before_ledger=$(sql_count "$db_csharp" "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")
apply_csharp "$db_csharp"
[[ "$(sql_count "$db_csharp" "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")" == "$before_ledger" ]]
assert_count "$db_csharp" "SELECT count(*) FROM app_plans WHERE id='$plan_id'::uuid" 1

# Both engines must reject partial legacy state and checksum drift.
if apply_csharp "$db_partial" >"$tmp/csharp-partial.log" 2>&1; then
  echo 'C# executor accepted partial legacy schema' >&2; exit 1
fi
grep -Fxq 'C# migration execution refused: Existing application schema is partial; manual repair needed' "$tmp/csharp-partial.log"
assert_count "$db_partial" "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename='app_schema_migrations'" 0
if apply_csharp "$db_one" >"$tmp/csharp-drift.log" 2>&1; then
  echo 'C# executor accepted checksum drift' >&2; exit 1
fi
grep -Fxq 'C# migration execution refused: Migration checksum/filename mismatch' "$tmp/csharp-drift.log"

# A legacy version 2 schema with no ledger, two C# runners and a Python runner
# compete under the same lock. Exactly one migration ledger may result.
setup_database "$db_csharp_legacy"
docker compose run --rm --no-deps -e MIGRATION_DB_NAME="$db_csharp_legacy" \
  --entrypoint bash schema-init -ec \
  'export PGPASSWORD="$DB_PASSWORD"; psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d "$MIGRATION_DB_NAME" -f /opt/radius/002_lab_accounts.sql' >/dev/null
apply_csharp "$db_csharp_legacy" >"$tmp/csharp-concurrent1.log" 2>&1 &
first=$!
apply_csharp "$db_csharp_legacy" >"$tmp/csharp-concurrent2.log" 2>&1 &
second=$!
run_migration "$db_csharp_legacy" >"$tmp/python-concurrent.log" 2>&1 &
third=$!
wait "$first"
wait "$second"
wait "$third"
verify_csharp "$db_csharp_legacy"
assert_count "$db_csharp_legacy" "SELECT count(*) FROM app_schema_migrations" 10
echo 'C# migration execution parity PASS: rollback, restart, legacy adoption, cross-engine locking and checksum refusal (isolated fixtures)'
echo 'Stage 02B PASS: fresh+populated, failure injection, restart, SHA-256 drift, mixed-version, concurrency, partial-schema refusal; all original fixture data preserved.'
