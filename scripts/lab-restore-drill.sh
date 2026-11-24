#!/usr/bin/env bash
# Prove an encrypted backup can be restored, but NEVER to the source database.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${LAB_BACKUP_ACK:-}" == "isolated-lab" ]] || { echo "Explicit isolated-lab acknowledgement required" >&2; exit 1; }
[[ $# -ge 1 && $# -le 3 && "$1" == /* && -f "$1" && -f "$1.sha256" ]] || { echo "Usage: lab-restore-drill.sh /absolute/path/backup.pgp [expected-plan-uuid expected-lab-user]" >&2; exit 1; }
[[ $# == 1 || $# == 3 ]] || { echo "Supply both expected fixture identifiers or neither" >&2; exit 1; }
backup="$1"
# Content comparison is opt-in for the populated isolated HTTPS CI fixture.
audit_digest="${LAB_AUDIT_RESTORE_SHA256:-}"
if [[ -n "$audit_digest" ]]; then
  [[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci && "$audit_digest" =~ ^[a-f0-9]{64}$ ]] || {
    echo "Audit content comparison requires isolated HTTPS CI and a valid digest" >&2; exit 1;
  }
fi
# Role restoration is opt-in and restricted to the same isolated HTTPS drill.
role_digest="${LAB_ROLE_RESTORE_SHA256:-}"
if [[ -n "$role_digest" ]]; then
  [[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci && -n "$audit_digest" && "$role_digest" =~ ^[a-f0-9]{64}$ ]] || {
    echo "Role restoration requires isolated HTTPS CI and valid content/role digests" >&2; exit 1;
  }
fi
[[ -n "${BACKUP_PASSPHRASE_FILE:-}" && -f "$BACKUP_PASSPHRASE_FILE" && ! -L "$BACKUP_PASSPHRASE_FILE" ]] || { echo "Private passphrase file required" >&2; exit 1; }
mode=$(stat -c %a "$BACKUP_PASSPHRASE_FILE")
[[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0077) == 0 )) || { echo "Insecure passphrase file permissions" >&2; exit 1; }
[[ -s "$BACKUP_PASSPHRASE_FILE" ]] || { echo "Passphrase file is empty" >&2; exit 1; }
[[ $(wc -c < "$BACKUP_PASSPHRASE_FILE") -ge 32 ]] || { echo "Passphrase must contain at least 32 bytes" >&2; exit 1; }
[[ -f .env ]] || { echo "Isolated-lab .env missing" >&2; exit 1; }
[[ "$backup" != *[[:space:]]* ]] || { echo "Backup paths containing spaces are not supported by the checksum manifest" >&2; exit 1; }
expected_hash=$(head -c 64 "$backup.sha256")
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid SHA-256 manifest" >&2; exit 1; }
# The generated manifest hash is verified against precisely the selected archive path.
printf "%s  %s\n" "$expected_hash" "$backup" | sha256sum -c --status || { echo "Encrypted archive checksum mismatch; restore refused" >&2; exit 1; }
command -v gpg >/dev/null || { echo "GnuPG is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required" >&2; exit 1; }
if [[ $# == 3 ]]; then
  [[ "$2" =~ ^[a-f0-9-]{36}$ && "$3" =~ ^lab_[a-f0-9]{12}$ ]] || { echo "Invalid isolated test fixture identifiers" >&2; exit 1; }
fi

compose_file=tests/isolated-restore.compose.yaml
candidate_image="${LAB_RESTORE_CANDIDATE_IMAGE:-}"
candidate_id="${LAB_RESTORE_CANDIDATE_ID:-}"
if [[ -n "$candidate_image" || -n "$candidate_id" ]]; then
  [[ "${CI:-}" == true && "${LAB_SECURITY_SCAN_ACK:-}" == isolated-ci &&
     "$candidate_id" =~ ^sha256:[a-f0-9]{64}$ &&
     "$candidate_image" == "radius-postgres-candidate:${candidate_id#sha256:}" ]] || {
    echo "Candidate restore requires exact local image and isolated CI acknowledgement" >&2; exit 1;
  }
  [[ "$(docker image inspect --format '{{.Id}}' "$candidate_image")" == "$candidate_id" ]] || exit 1
  compose_file=tests/isolated-restore-alpine.compose.yaml
fi
restore_project="radiusrestore$(python3 -c 'import secrets;print(secrets.token_hex(4))')"
cleanup() {
  # This down -v targets ONLY the fresh, randomly named restoration project.
  [[ "$restore_project" =~ ^radiusrestore[a-f0-9]{8}$ ]] || return 0
  docker compose -p "$restore_project" -f "$compose_file" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT
set -a; source .env; set +a
started_at=$(date +%s)
docker compose -p "$restore_project" -f "$compose_file" up -d --wait restore-db
# Never emit decrypted archive bytes onto the host filesystem.
gpg --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
  --passphrase-file "$BACKUP_PASSPHRASE_FILE" --decrypt "$backup" |
  docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
    pg_restore -U radius -d radius --no-owner --no-acl --exit-on-error
# Verify the official RADIUS tables and all pre-existing application tables exist.
count=$(docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
  psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tAc "
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname='public' AND tablename IN
 ('radcheck','radreply','radgroupcheck','radgroupreply','radusergroup','radacct','radpostauth','nas',
  'app_plans','app_lab_accounts','app_nas_drafts','app_nas_draft_events','app_lab_account_owners','app_lab_owner_transfers',
  'app_admin_audit_events','app_admin_sessions','app_schema_migrations',
  'AspNetUsers','AspNetRoles','AspNetUserRoles','AspNetUserClaims','AspNetRoleClaims','AspNetUserLogins','AspNetUserTokens')
")
count="${count//[[:space:]]/}"
[[ "$count" == "24" ]] || { echo "Restored schema incomplete: $count of 24 expected tables for schema 009" >&2; exit 1; }
docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
  psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tAc "
SELECT count(*) FROM information_schema.columns
WHERE table_schema='public' AND table_name='app_lab_account_owners' AND column_name='ownership_version'
" | grep -qx 1
# Verify restored 009 index definitions and validity, not just table count.
docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
  psql -X -v ON_ERROR_STOP=1 -U radius -d radius < tests/accounting_indexes_verify.sql >/dev/null
docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
  psql -X -v ON_ERROR_STOP=1 -U radius -d radius < tests/accounting_quality_verify.sql >/dev/null
# Verify both restored statement-level guards are enabled ALWAYS, including
# replication-role mode. The restore is isolated and contains no production database.
docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
  psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tAc "
SELECT count(*) FROM pg_trigger
WHERE NOT tgisinternal AND tgenabled='A' AND tgtype=58
  AND tgfoid=to_regprocedure('public.app_reject_audit_mutation()')
  AND ((tgrelid='public.app_admin_audit_events'::regclass AND tgname='audit_append_only')
    OR (tgrelid='public.app_lab_owner_transfers'::regclass AND tgname='ownership_history_append_only'))
" | grep -qx 2
docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
  psql -X -v ON_ERROR_STOP=1 -U radius -d radius < tests/audit_append_only_verify.sql >/dev/null
if [[ $# == 3 ]]; then
  check=$(docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
    psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tA -v plan_id="$2" -v name="$3" <<'SQL'
SELECT CASE WHEN
  (SELECT count(*) FROM app_plans WHERE id=:'plan_id'::uuid)=1
  AND (SELECT count(*) FROM radcheck WHERE username=:'name' AND attribute='Cleartext-Password')=1
THEN 'RESTORE_FIXTURE_OK' ELSE 'RESTORE_FIXTURE_MISSING' END;
SQL
)
  [[ "$check" == "RESTORE_FIXTURE_OK" ]] || { echo "Expected fixture not recovered" >&2; exit 1; }
fi
if [[ -n "$audit_digest" ]]; then
  restored_digest=$(docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
    psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius < tests/audit_recovery_fingerprint.sql | sha256sum | cut -d ' ' -f1)
  [[ "$restored_digest" == "$audit_digest" ]] || {
    echo "Restored audit content fingerprint mismatch" >&2; exit 1;
  }
  echo "Restored populated audit and ownership content fingerprint PASS"
fi
if [[ -n "$role_digest" ]]; then
  bash scripts/restore-runtime-roles-smoke.sh "$restore_project" "$compose_file" "$role_digest"
fi
# A candidate is never attached to the original volume. Confirm the exact
# scanned image, non-root server process, and representative locale semantics.
if [[ -n "$candidate_image" ]]; then
  container=$(docker compose -p "$restore_project" -f "$compose_file" ps -q restore-db)
  [[ "$(docker inspect --format '{{.Image}}' "$container")" == "$candidate_id" ]] || exit 1
  docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db sh -ec '
    uid=$(id -u postgres)
    test "$uid" != 0
    test "$(awk "/^Uid:/{print \$2}" /proc/1/status)" = "$uid"
  '
  metadata_sql="SELECT datlocprovider, datcollate, datctype, COALESCE(daticulocale,'none'), COALESCE(pg_database_collation_actual_version(oid),'none') FROM pg_database WHERE datname=current_database()"
  echo "Source locale metadata:"
  docker compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "$metadata_sql"
  echo "Candidate locale metadata:"
  docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
    psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "$metadata_sql"
  # A new cluster must actually use the chosen ICU provider and a valid
  # catalog version. No silent fallback to musl or rewriting catalog metadata.
  docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
    psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "
SELECT CASE WHEN datlocprovider='i' AND daticulocale='en-US'
  AND pg_encoding_to_char(encoding)='UTF8'
  AND datcollversion IS NOT NULL
  AND datcollversion=pg_database_collation_actual_version(oid)
THEN 'ICU_LOCALE_OK' ELSE 'ICU_LOCALE_INVALID' END
FROM pg_database WHERE datname=current_database()" | grep -qx ICU_LOCALE_OK
  # Arabic and Latin representative identifiers; deterministic tie-break.
  order_sql="SELECT value FROM (VALUES ('a'),('A'),('z'),('Z'),('é'),('e'),('أ'),('ا'),('ب'),('ي'),('10'),('2')) AS samples(value) ORDER BY value, value COLLATE \"C\""
  source_order=$(docker compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "$order_sql" | sha256sum | cut -d ' ' -f1)
  target_order=$(docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
    psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "$order_sql" | sha256sum | cut -d ' ' -f1)
  echo "Representative source/candidate collation fingerprints: $source_order $target_order"
  if [[ "$source_order" != "$target_order" ]]; then
    echo "Default collation differs; explicit compatibility decision required before adoption" >&2
    exit 1
  fi
  # Compare application ordering on restored records too. Only fingerprints
  # are emitted; neither account names nor plan names leave the database.
  for order_sql in \
      'SELECT jsonb_build_array(id,name)::text FROM app_plans ORDER BY name,id' \
      'SELECT jsonb_build_array(username,plan_id)::text FROM app_lab_accounts ORDER BY username,plan_id'; do
    source_order=$(docker compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "$order_sql" | sha256sum | cut -d ' ' -f1)
    target_order=$(docker compose -p "$restore_project" -f "$compose_file" exec -T restore-db \
      psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "$order_sql" | sha256sum | cut -d ' ' -f1)
    [[ "$source_order" == "$target_order" ]] || {
      echo "Restored application ordering differs; candidate adoption refused" >&2
      exit 1
    }
  done
  echo "Scanned candidate runtime UID and representative default collation PASS"
  echo "Restored application plan and account ordering fingerprints PASS"
fi
echo "Encrypted backup restore verified in disposable PostgreSQL; elapsed seconds: $(($(date +%s)-started_at))"
