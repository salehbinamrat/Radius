#!/usr/bin/env bash
set -euo pipefail
set +x
# Use the same strict reader as the daemon and health probe. Reject malformed
# or conflicting sources before creating a temporary file or contacting SQL.
db_password=$(bash /opt/radius/radius_secret_input.sh DB_PASSWORD)
# Use a private libpq password file instead of exporting the password.
umask 077
pgpass=$(mktemp)
trap 'rm -f -- "$pgpass"' EXIT
printf 'db:5432:radius:radius:%s\n' "$db_password" > "$pgpass"
unset db_password PGPASSWORD
export PGPASSFILE="$pgpass"
SCHEMA=/etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql
if [[ ! -f "$SCHEMA" ]]; then
  echo "FreeRADIUS distribution does not include $SCHEMA" >&2; exit 1
fi
# Fail closed if any subset of the official FreeRADIUS tables exists.
# A previously interrupted init must NOT be mistaken for a complete installation.
SCHEMA_TABLE_COUNT=$(psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius -tAc "
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname='public'
  AND tablename IN
      ('radcheck','radreply','radgroupcheck','radgroupreply',
       'radusergroup','radacct','radpostauth','nas')
")
SCHEMA_TABLE_COUNT="${SCHEMA_TABLE_COUNT//[[:space:]]/}"
if [[ "$SCHEMA_TABLE_COUNT" == 0 ]]; then
  psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d radius -f "$SCHEMA"
  echo 'Official FreeRADIUS PostgreSQL schema installed transactionally.'
elif [[ "$SCHEMA_TABLE_COUNT" == 8 ]]; then
  echo 'FreeRADIUS tables already exist; initial schema init skipped.'
else
  echo "Refusing an incomplete FreeRADIUS schema ($SCHEMA_TABLE_COUNT of 8 tables). Backup and repair manually." >&2
  exit 1
fi

# app_plans is installed by PostgreSQL initial startup; never silently recreate it in an existing data volume.
APP_TABLE_PRESENT=$(psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius -tAc "SELECT to_regclass('public.app_plans') IS NOT NULL")
if [[ "$APP_TABLE_PRESENT" != "t" ]]; then
  echo 'Missing app_plans in a persistent database; refusing automatic repair.' >&2
  exit 1
fi

# Versioned transaction-safe PostgreSQL application migrations 001_app.sql,
# 002_lab_accounts.sql, 003_accounting.sql and 004_nas_drafts.sql.
# Existing objects are adopted only after schema completeness checks.
python3 /opt/radius/migrate.py
