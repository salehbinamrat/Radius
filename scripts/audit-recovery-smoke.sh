#!/usr/bin/env bash
# Restore actual audit and transfer events created by the preceding HTTPS tests.
# Source must be the randomly named disposable CI project, never the main lab.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci ]] || {
  echo 'Audit recovery requires disposable HTTPS CI' >&2; exit 1;
}
[[ $# == 2 && "$1" =~ ^radiushttps[a-f0-9]{8}$ && "$2" == tests/admin-https.compose.yaml ]] || {
  echo 'Unexpected HTTPS fixture identity' >&2; exit 1;
}
project="$1"
compose_file="$2"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export LAB_BACKUP_ACK=isolated-lab
export BACKUP_PASSPHRASE_FILE="$tmp/key"
python3 -c 'import secrets; print(secrets.token_hex(32))' > "$BACKUP_PASSPHRASE_FILE"
sql() {
  docker compose -p "$project" -f "$compose_file" exec -T db \
    psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"
}
# Require genuine existing fixture transfers and their correlated success events.
# Never accept an empty or incomplete history as proof of recovery.
sql <<'SQL' | grep -qx POPULATED_AUDIT_OK
SELECT CASE WHEN
  (SELECT count(*) FROM app_lab_owner_transfers WHERE username='lab_0000000000a1')=2
  AND (SELECT count(*) FROM app_lab_owner_transfers WHERE username='lab_0000000000e1')=2
  AND (SELECT count(*) FROM app_lab_account_owners WHERE username IN ('lab_0000000000a1','lab_0000000000e1') AND owner_user_id='ci-owner-a')=2
  AND NOT EXISTS (
    SELECT 1 FROM app_lab_owner_transfers t
    WHERE (SELECT count(*) FROM app_admin_audit_events a
           WHERE a.correlation_id=t.id AND a.actor_user_id=t.actor_user_id
             AND a.subject_id=t.username AND a.action='voucher_owner_transferred'
             AND a.outcome='success')<>1)
  AND EXISTS (SELECT 1 FROM app_admin_audit_events WHERE action='plan_created' AND outcome='success' AND actor_user_id IS NOT NULL)
  AND EXISTS (SELECT 1 FROM app_admin_audit_events WHERE action='login_failure' AND outcome='denied')
THEN 'POPULATED_AUDIT_OK' ELSE 'POPULATED_AUDIT_MISSING' END;
SQL
fingerprint() {
  sql < tests/audit_recovery_fingerprint.sql | sha256sum | cut -d ' ' -f1
}
before=$(fingerprint)
archive="$tmp/audit-snapshot.pgp"
# Scope Compose selection to this one backup invocation. The helper uses the
# normal encrypted pipeline, with no plaintext archive or production target.
COMPOSE_PROJECT_NAME="$project" COMPOSE_FILE="$compose_file" bash scripts/lab-backup.sh "$archive"
[[ "$(fingerprint)" == "$before" ]] || {
  echo 'Source audit changed during backup; comparison refused' >&2; exit 1;
}
LAB_AUDIT_RESTORE_SHA256="$before" bash scripts/lab-restore-drill.sh "$archive"
# Negative control: a valid archive but an incorrect expected content digest
# must fail specifically at the comparison, not at decryption or schema checks.
wrong=$(python3 - "$before" <<'PY'
import sys
digest=sys.argv[1]
print(('1' if digest[0]=='0' else '0')+digest[1:])
PY
)
if LAB_AUDIT_RESTORE_SHA256="$wrong" bash scripts/lab-restore-drill.sh "$archive" >"$tmp/wrong.log" 2>&1; then
  echo 'Incorrect expected audit fingerprint was accepted' >&2; exit 1
fi
grep -Fxq 'Restored audit content fingerprint mismatch' "$tmp/wrong.log"
[[ "$(fingerprint)" == "$before" ]] || {
  echo 'Source audit changed during restore drill' >&2; exit 1;
}
echo 'Populated HTTPS audit recovery, mismatch rejection and unchanged source PASS'
