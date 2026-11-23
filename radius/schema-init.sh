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
  echo 'FreeRADIUS tables already exist; schema init skipped.'
  exit 0
fi
psql -X -v ON_ERROR_STOP=1 -h db -U radius -d radius -f "$SCHEMA"
echo 'Official FreeRADIUS PostgreSQL schema installed.'
