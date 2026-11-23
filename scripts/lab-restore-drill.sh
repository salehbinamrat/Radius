#!/usr/bin/env bash
# Prove an encrypted backup can be restored, but NEVER to the source database.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${LAB_BACKUP_ACK:-}" == "isolated-lab" ]] || { echo "Explicit isolated-lab acknowledgement required" >&2; exit 1; }
[[ $# -ge 1 && $# -le 3 && "$1" == /* && -f "$1" && -f "$1.sha256" ]] || { echo "Usage: lab-restore-drill.sh /absolute/path/backup.pgp [expected-plan-uuid expected-lab-user]" >&2; exit 1; }
[[ $# == 1 || $# == 3 ]] || { echo "Supply both expected fixture identifiers or neither" >&2; exit 1; }
backup="$1"
[[ -n "${BACKUP_PASSPHRASE_FILE:-}" && -f "$BACKUP_PASSPHRASE_FILE" && ! -L "$BACKUP_PASSPHRASE_FILE" ]] || { echo "Private passphrase file required" >&2; exit 1; }
mode=$(stat -c %a "$BACKUP_PASSPHRASE_FILE")
[[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0077) == 0 )) || { echo "Insecure passphrase file permissions" >&2; exit 1; }
[[ -s "$BACKUP_PASSPHRASE_FILE" ]] || { echo "Passphrase file is empty" >&2; exit 1; }
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
  'app_plans','app_lab_accounts','app_nas_drafts','app_nas_draft_events')
")
count="${count//[[:space:]]/}"
[[ "$count" == "12" ]] || { echo "Restored schema incomplete: $count of 12 expected tables" >&2; exit 1; }
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
echo "Encrypted backup restore verified in disposable PostgreSQL; elapsed seconds: $(($(date +%s)-started_at))"
