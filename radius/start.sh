#!/usr/bin/env bash
set -euo pipefail
# Resolve both inputs and render directly, without secrets in sed arguments.
bash /opt/radius/radius_secret_input.sh render
cp /opt/radius/default.site /etc/freeradius/3.0/sites-available/default
ln -sfn ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
# This deployment serves PAP/CHAP/MS-CHAP, not EAP. Disable unused listeners
# and EAP methods implicated in CVE-2026-127029/127030; not a package-level fix.
rm -f /etc/freeradius/3.0/mods-enabled/eap \
      /etc/freeradius/3.0/sites-enabled/inner-tunnel
chown root:freerad /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/clients.conf
chmod 640 /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/clients.conf
# Verify configuration before serving any authentication packets.
if ! freeradius -C -l stdout; then
  echo 'FreeRADIUS configuration validation failed; server not started.' >&2
  exit 1
fi
exec freeradius -f -l stdout
