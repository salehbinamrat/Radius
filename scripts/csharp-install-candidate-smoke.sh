#!/usr/bin/env bash
# Fresh installation and encrypted restore of the C# candidate. Isolated CI only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${CSHARP_INSTALL_TEST_ACK:-}" == isolated-ci ]] || {
  echo 'C# installation acceptance requires isolated CI' >&2; exit 1;
}
umask 077
tmp=$(mktemp -d)
created=()
cleanup() {
  local status=$?
  for db in "${created[@]}"; do
    if [[ "$db" =~ ^radius_mig_[a-f0-9]{8}$ ]]; then
      docker compose exec -T db dropdb -U radius --if-exists "$db" >/dev/null || status=1
    else
      status=1
    fi
  done
  rm -rf -- "$tmp"
  exit "$status"
}
trap cleanup EXIT
new_db() {
  local name="$1"
  [[ "$name" =~ ^radius_mig_[a-f0-9]{8}$ ]] || exit 1
  docker compose exec -T db createdb -U radius "$name"
  created+=("$name")
}
fresh="radius_mig_$(openssl rand -hex 4)"
restored="radius_mig_$(openssl rand -hex 4)"
invalid="radius_mig_$(openssl rand -hex 4)"
[[ "$fresh" != "$restored" && "$fresh" != "$invalid" && "$restored" != "$invalid" ]]
new_db "$fresh"
new_db "$restored"
new_db "$invalid"
# Use the official SQL from the actual daemon image, not a copied or rewritten schema.
radius_container=$(docker compose ps -q radius)
api_container=$(docker compose ps -q api)
[[ -n "$radius_container" && -n "$api_container" ]]
for container in "$radius_container" "$api_container"; do
  image=$(docker inspect --format '{{.Image}}' "$container")
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]]
done
docker compose exec -T radius cat /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql >"$tmp/official.sql"
test -s "$tmp/official.sql"
# Public upstream SQL only; allow the non-root API process to read the bind mount.
chmod 644 "$tmp/official.sql"
printf 'Official installation SQL SHA-256: %s\n' "$(sha256sum "$tmp/official.sql" | cut -d ' ' -f1)"
sql() {
  local db="$1"
  shift
  docker compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d "$db" "$@"
}
baseline() {
  sql "$1" -1 -f /docker-entrypoint-initdb.d/001_app.sql >/dev/null
}
install_candidate() {
  local db="$1"
  docker compose run --rm --no-deps -e CI=true -e LAB_MIGRATION_TEST_MODE=isolated-ci \
    -e MIGRATION_DB_NAME="$db" -e MIGRATION_FAIL_AFTER_SQL_VERSION= \
    -v "$PWD/database:/opt/radius:ro" -v "$tmp/official.sql:/opt/official.sql:ro" \
    --entrypoint dotnet api /app/RadiusManager.Api.dll --migration-install-candidate /opt/radius /opt/official.sql
}
refuse() {
  local db="$1" reason="$2"
  if install_candidate "$db" >"$tmp/refusal.log" 2>&1; then
    echo 'C# installer accepted an invalid baseline' >&2; exit 1
  fi
  grep -Fxq "C# migration execution refused: $reason" "$tmp/refusal.log"
}
official_count() {
  sql "$1" -c "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename IN ('radcheck','radreply','radgroupcheck','radgroupreply','radusergroup','radacct','radpostauth','nas')"
}
# Missing app baseline must not create official tables. Partial official schema
# must not be repaired or adopted, and must not create a ledger.
refuse "$invalid" 'Missing app_plans baseline; refusing automatic repair'
[[ "$(official_count "$invalid")" == 0 ]]
baseline "$invalid"
sql "$invalid" -c 'CREATE TABLE public.radcheck(id integer)' >/dev/null
refuse "$invalid" 'Official FreeRADIUS schema is partial; refusing automatic repair'
[[ "$(official_count "$invalid")" == 1 ]]
[[ "$(sql "$invalid" -c "SELECT to_regclass('public.app_schema_migrations') IS NULL")" == t ]]

baseline "$fresh"
[[ "$(official_count "$fresh")" == 0 ]]
install_candidate "$fresh"
[[ "$(official_count "$fresh")" == 8 ]]
[[ "$(sql "$fresh" -c "SELECT count(*) FROM app_schema_migrations WHERE engine_version='3.0.0-csharp-lab'")" == 10 ]]

# Synthetic data exercises real schema and 64-bit accounting, never a customer.
sql "$fresh" <<'SQL' >/dev/null
INSERT INTO app_plans(id,name,upload_kbps,download_kbps)
VALUES ('11111111-1111-4111-8111-111111111111','csharp-install-fixture',256,1024);
INSERT INTO app_lab_accounts(username,plan_id)
VALUES ('lab_000000000001','11111111-1111-4111-8111-111111111111');
INSERT INTO radacct(acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctstoptime,acctinputoctets,acctoutputoctets)
VALUES ('install-fixture','install-fixture','lab_000000000001','10.255.70.21',now(),now(),4294967297,8589934593);
INSERT INTO app_admin_audit_events(action,subject_kind,subject_id,outcome,correlation_id)
VALUES ('synthetic-install','plan','11111111-1111-4111-8111-111111111111','success','22222222-2222-4222-8222-222222222222');
SQL
fingerprint() {
  sql "$1" -c "
    SELECT jsonb_build_array(
      (SELECT jsonb_agg(to_jsonb(m) ORDER BY version) FROM app_schema_migrations m),
      (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM app_plans p),
      (SELECT jsonb_agg(to_jsonb(a) ORDER BY username) FROM app_lab_accounts a),
      (SELECT jsonb_agg(to_jsonb(r) ORDER BY radacctid) FROM radacct r),
      (SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM app_admin_audit_events e),
      (SELECT jsonb_agg(to_jsonb(r) ORDER BY \"Id\") FROM \"AspNetRoles\" r)
    )" | sha256sum | cut -d ' ' -f1
}
before=$(fingerprint "$fresh")
install_candidate "$fresh"
[[ "$(fingerprint "$fresh")" == "$before" ]]
# Reuse the existing database security checks without changing their semantics.
for file in tests/accounting_indexes_verify.sql tests/accounting_quality_verify.sql tests/audit_append_only_verify.sql; do
  sql "$fresh" <"$file" >/dev/null
done

# Stream a logical dump directly into GnuPG. No plaintext backup on the host.
openssl rand -hex 32 >"$tmp/passphrase"
docker compose exec -T db pg_dump -U radius -d "$fresh" --format=custom --no-owner --no-acl |
  gpg --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
    --passphrase-file "$tmp/passphrase" --symmetric --cipher-algo AES256 \
    --compress-algo none --output "$tmp/snapshot.pgp"
test -s "$tmp/snapshot.pgp"
sha256sum "$tmp/snapshot.pgp" >"$tmp/snapshot.sha256"
sha256sum --check --status "$tmp/snapshot.sha256"
gpg --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
  --passphrase-file "$tmp/passphrase" --decrypt "$tmp/snapshot.pgp" |
  docker compose exec -T db pg_restore -U radius -d "$restored" --no-owner --no-acl --single-transaction --exit-on-error
[[ "$(fingerprint "$restored")" == "$before" ]]
install_candidate "$restored"
[[ "$(fingerprint "$restored")" == "$before" ]]
[[ "$(fingerprint "$fresh")" == "$before" ]]
for file in tests/accounting_indexes_verify.sql tests/accounting_quality_verify.sql tests/audit_append_only_verify.sql; do
  sql "$restored" <"$file" >/dev/null
done
[[ "$(sql "$restored" -c "SELECT upload_bytes::text||':'||download_bytes::text||':'||session_count::text||':'||anomalous_sessions::text FROM app_lab_usage_snapshot('lab_000000000001')")" == '4294967297:8589934593:1:0' ]]
echo 'C# candidate fresh schema installation, encrypted restore and exact replay PASS (isolated CI)'
