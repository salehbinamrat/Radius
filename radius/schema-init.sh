#!/usr/bin/env bash
set -euo pipefail
if [[ ! "${DB_PASSWORD:-}" =~ ^[a-f0-9]{48}$ ]]; then
  echo 'Invalid DB_PASSWORD' >&2; exit 1
fi
export PGPASSWORD="$DB_PASSWORD"
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

# Each existing additive SQL file runs atomically. New migration ledgers require separate schema approval.
psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d radius -f /opt/radius/002_lab_accounts.sql
psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d radius -f /opt/radius/003_accounting.sql
psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d radius -f /opt/radius/004_nas_drafts.sql
echo 'Existing additive application SQL scripts applied with transaction guards.'
