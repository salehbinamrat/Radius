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
# Serialize the guard and official schema creation in ONE transaction.
# This two-int advisory lock conflicts with the session lock used by both
# migrators. It is released on commit/rollback before invoking migrate.py.
psql -X -v ON_ERROR_STOP=1 -1 -h db -U radius -d radius \
  -v schema_file="$SCHEMA" -f - <<'BOOTSTRAP_SQL'
SET LOCAL lock_timeout TO '60s';
SELECT pg_advisory_xact_lock(725134019, 20261124);
DO $guard$
DECLARE
  existing integer;
BEGIN
  IF to_regclass('public.app_plans') IS NULL THEN
    RAISE EXCEPTION 'Missing app_plans in a persistent database; refusing automatic repair.';
  END IF;
  SELECT count(*) INTO existing FROM pg_catalog.pg_tables
  WHERE schemaname='public'
    AND tablename IN
        ('radcheck','radreply','radgroupcheck','radgroupreply',
         'radusergroup','radacct','radpostauth','nas');
  IF existing NOT IN (0, 8) THEN
    RAISE EXCEPTION 'Refusing an incomplete FreeRADIUS schema (% of 8 tables). Backup and repair manually.', existing;
  END IF;
END
$guard$;
SELECT NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_tables
  WHERE schemaname='public' AND tablename='radcheck'
) AS bootstrap_needed \gset
\if :bootstrap_needed
  \i :schema_file
  \echo Official FreeRADIUS PostgreSQL schema installed transactionally.
\else
  \echo FreeRADIUS tables already exist; initial schema init skipped.
\endif
BOOTSTRAP_SQL

# Versioned transaction-safe PostgreSQL application migrations 001_app.sql,
# 002_lab_accounts.sql, 003_accounting.sql and 004_nas_drafts.sql.
# Existing objects are adopted only after schema completeness checks.
python3 /opt/radius/migrate.py
