#!/usr/bin/env bash
set -euo pipefail
# Resolve both inputs and render directly, without secrets in sed arguments.
python3 /opt/radius/radius_secret_input.py render
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
