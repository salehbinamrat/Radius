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
# Schema must only be initialized once; never overwrite an existing RADIUS database.
FOUND=$(psql -X -h db -U radius -d radius -tAc "SELECT to_regclass('public.radcheck') IS NOT NULL")
if [[ "$FOUND" == 't' ]]; then
  echo 'FreeRADIUS tables already exist; initial schema init skipped.'
else
  psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius -f "$SCHEMA"
  echo 'Official FreeRADIUS PostgreSQL schema installed.'
fi
# Apply additive app migrations on EVERY start, including existing databases.
psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius \
  -f /opt/radius/002_lab_accounts.sql
psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius \
  -f /opt/radius/003_accounting.sql
psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius \
  -f /opt/radius/004_nas_drafts.sql
echo 'Additive application migrations verified.'
