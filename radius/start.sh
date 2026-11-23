#!/usr/bin/env bash
set -euo pipefail
for v in DB_PASSWORD RADIUS_SECRET RADIUS_CLIENT_CIDR; do
  if [[ -z "${!v:-}" ]]; then echo "Missing $v" >&2; exit 1; fi
done
# Phase-one secrets only use hexadecimal; reject unsafe syntax rather than injecting config.
for v in DB_PASSWORD RADIUS_SECRET; do
  if [[ ! "${!v}" =~ ^[a-f0-9]{48}$ ]]; then
    echo "$v must be 48 hexadecimal characters created by setup.sh" >&2; exit 1
  fi
done
if [[ ! "$RADIUS_CLIENT_CIDR" =~ ^[0-9./]+$ ]]; then
  echo 'Invalid RADIUS_CLIENT_CIDR' >&2; exit 1
fi
cp /opt/radius/sql.template /etc/freeradius/3.0/mods-available/sql
sed -i "s/__DB_PASSWORD__/$DB_PASSWORD/g" /etc/freeradius/3.0/mods-available/sql
cp /opt/radius/clients.template /etc/freeradius/3.0/clients.conf
sed -i "s/__RADIUS_SECRET__/$RADIUS_SECRET/g; s|__RADIUS_CLIENT_CIDR__|$RADIUS_CLIENT_CIDR|g" /etc/freeradius/3.0/clients.conf
cp /opt/radius/default.site /etc/freeradius/3.0/sites-available/default
ln -sfn ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
chown root:freerad /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/clients.conf
chmod 640 /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/clients.conf
# Verify configuration before serving any authentication packets.
if ! freeradius -C -l stdout; then
  echo 'FreeRADIUS configuration validation failed; server not started.' >&2
  exit 1
fi
exec freeradius -f -l stdout
