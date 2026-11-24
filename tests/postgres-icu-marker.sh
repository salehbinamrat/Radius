#!/bin/sh
set -eu
# Executed by upstream initdb only, as postgres, after initial SQL succeeds.
# Never mark a cluster based on a version string alone.
actual=$(psql -X -qAt -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "
SELECT CASE WHEN datlocprovider='i' AND daticulocale='en-US'
  AND pg_encoding_to_char(encoding)='UTF8'
  AND datcollversion IS NOT NULL
  AND datcollversion=pg_database_collation_actual_version(oid)
THEN 'ICU_LOCALE_OK' ELSE 'ICU_LOCALE_INVALID' END
FROM pg_database WHERE datname=current_database()")
[ "$actual" = ICU_LOCALE_OK ]
umask 077
printf '%s\n' 'radius-pg16-icu-en-US-v1' > "$PGDATA/.radius-pg16-icu.tmp"
mv "$PGDATA/.radius-pg16-icu.tmp" "$PGDATA/.radius-pg16-icu"
