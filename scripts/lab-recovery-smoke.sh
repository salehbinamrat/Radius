#!/usr/bin/env bash
# Deterministic isolated CI drill: seed -> repeat existing SQL -> encrypt -> restore -> verify -> cleanup.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo "Isolated lab .env missing" >&2; exit 1; }
umask 077
temp_dir=$(mktemp -d)
plan_id=$(python3 -c 'import uuid;print(uuid.uuid4())')
username="lab_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
plan_name="stage2_recovery_$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
password=$(python3 -c 'import secrets;print(secrets.token_hex(24))')
cleanup() {
  docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -v plan_id="$plan_id" -v name="$username" <<'SQL' >/dev/null 2>&1 || true
DELETE FROM radcheck WHERE username=:'name';
DELETE FROM app_plans WHERE id=:'plan_id'::uuid;
SQL
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

export LAB_BACKUP_ACK=isolated-lab
export BACKUP_PASSPHRASE_FILE="$temp_dir/key"
python3 - "$BACKUP_PASSPHRASE_FILE" <<'PY'
from pathlib import Path
import secrets, sys
Path(sys.argv[1]).write_text(secrets.token_hex(32)+'\n', encoding='ascii')
PY
chmod 600 "$BACKUP_PASSPHRASE_FILE"

# All fixture identifiers are randomly generated and SQL-quoted by psql.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius \
  -v plan_id="$plan_id" -v plan_name="$plan_name" -v name="$username" -v password="$password" <<'SQL' >/dev/null
INSERT INTO app_plans (id,name,download_kbps,upload_kbps)
VALUES (:'plan_id'::uuid,:'plan_name',1024,256);
INSERT INTO radcheck (username,attribute,op,value)
VALUES (:'name','Cleartext-Password',':=',:'password');
SQL
unset password

# Re-run only the already-built initializer. Starting its dependencies would
# honor db's pull_policy: build and silently replace the tested database image.
db_before=$(docker compose ps -q db)
[[ -n "$db_before" && "$db_before" != *$'\n'* ]]
db_image_before=$(docker inspect --format '{{.Image}}' "$db_before")
[[ "$db_image_before" =~ ^sha256:[a-f0-9]{64}$ ]]
db_tag_before=$(docker image inspect --format '{{.Id}}' radius-postgres-local:16.16-icu)
[[ "$db_image_before" == "$db_tag_before" ]]
schema_before=$(docker compose ps -aq schema-init)
[[ -n "$schema_before" && "$schema_before" != *$'\n'* ]]
schema_image_before=$(docker inspect --format '{{.Image}}' "$schema_before")
[[ "$schema_image_before" =~ ^sha256:[a-f0-9]{64}$ ]]
# --no-deps prevents dependency recreation; --pull never forbids a pull.
docker compose run --rm --no-deps --pull never schema-init >/dev/null
[[ "$(docker compose ps -q db)" == "$db_before" ]]
[[ "$(docker inspect --format '{{.Image}}' "$db_before")" == "$db_image_before" ]]
[[ "$(docker image inspect --format '{{.Id}}' radius-postgres-local:16.16-icu)" == "$db_tag_before" ]]
[[ "$(docker compose ps -aq schema-init)" == "$schema_before" ]]
[[ "$(docker inspect --format '{{.Image}}' "$schema_before")" == "$schema_image_before" ]]
echo 'Recovery replay preserved original database and initializer image identities PASS'
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tA -v plan_id="$plan_id" -v name="$username" <<'SQL' | grep -qx REPLAY_OK
SELECT CASE WHEN
  (SELECT count(*) FROM app_plans WHERE id=:'plan_id'::uuid)=1
  AND (SELECT count(*) FROM radcheck WHERE username=:'name')=1
THEN 'REPLAY_OK' ELSE 'REPLAY_FAILED' END;
SQL

archive="$temp_dir/snapshot.pgp"
bash scripts/lab-backup.sh "$archive"
bash scripts/lab-restore-drill.sh "$archive" "$plan_id" "$username"

# Deliberate encrypted-archive corruption must fail before any restore project is started.
tampered="$temp_dir/tampered.pgp"
cp "$archive" "$tampered"
python3 - "$tampered" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
with p.open('r+b') as f:
    f.seek(16)
    x=f.read(1)
    assert x, 'backup unexpectedly too small'
    f.seek(16)
    f.write(bytes((x[0]^0xA5,)))
PY
expected_hash=$(head -c 64 "$archive.sha256")
printf "%s  %s\n" "$expected_hash" "$tampered" > "$tampered.sha256"
if bash scripts/lab-restore-drill.sh "$tampered" "$plan_id" "$username" >/dev/null 2>&1; then
  echo "Corrupted encrypted archive was incorrectly accepted" >&2
  exit 1
fi

# Source DB must still contain the fixture; the restore helper never touches it.
docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U radius -d radius -tA -v plan_id="$plan_id" -v name="$username" <<'SQL' | grep -qx SOURCE_INTACT
SELECT CASE WHEN
 (SELECT count(*) FROM app_plans WHERE id=:'plan_id'::uuid)=1
 AND (SELECT count(*) FROM radcheck WHERE username=:'name')=1
THEN 'SOURCE_INTACT' ELSE 'SOURCE_CHANGED' END;
SQL
echo "Stage 02A migration replay, encrypted backup, clean restore and corruption refusal PASS"
