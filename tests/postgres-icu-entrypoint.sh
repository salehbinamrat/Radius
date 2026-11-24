#!/bin/sh
set -eu
# Never initialize or start an unrecognized physical PostgreSQL cluster.
case "${1:-}" in
  postgres|-*)
    : "${PGDATA:?Missing PGDATA}"
    marker="$PGDATA/.radius-pg16-icu"
    if [ -e "$PGDATA/PG_VERSION" ]; then
      if [ ! -f "$marker" ] || [ -L "$marker" ] || [ "$(cat "$marker")" != 'radius-pg16-icu-en-US-v1' ] || [ "$(cat "$PGDATA/PG_VERSION")" != 16 ]; then
        echo 'Refusing unverified physical PostgreSQL data; use encrypted logical backup and isolated restore.' >&2
        exit 1
      fi
    elif [ -e "$PGDATA" ]; then
      [ -d "$PGDATA" ] || exit 1
      entries=$(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit)
      [ -z "$entries" ] || { echo 'Refusing nonempty uninitialized PostgreSQL data directory.' >&2; exit 1; }
    fi
    [ "${POSTGRES_INITDB_ARGS:-}" = '--locale-provider=icu --icu-locale=en-US --locale=en_US.utf8 --encoding=UTF8' ] || {
      echo 'Refusing unsupported PostgreSQL locale initialization.' >&2; exit 1;
    }
    ;;
esac
exec docker-entrypoint.sh "$@"
