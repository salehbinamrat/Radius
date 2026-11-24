#!/usr/bin/env bash
# Shared native image configuration: build-time and disposable source probe.
set -euo pipefail
if ! grep -q '^freerad:' /etc/group; then addgroup -S freerad; fi
if ! id freerad >/dev/null 2>&1; then adduser -S -D -H -G freerad freerad; fi
mkdir -p /etc/freeradius
ln -s /opt/etc/raddb /etc/freeradius/3.0
mkdir -p /opt/var/run/radiusd /opt/var/log/radius/radacct
chown -R freerad:freerad /opt/var
# The upstream image uses its own configuration ownership/modes. The
# application runs as freerad, so normalize only this disposable native
# configuration tree (never symlink targets outside it). Keep root as owner,
# allow the daemon group to read/traverse, and deny group writes/world access.
config=/opt/etc/raddb
find "$config" -type d -exec chown root:freerad {} +
find "$config" -type d -exec chmod 0750 {} +
find "$config" -type f -exec chown root:freerad {} +
find "$config" -type f -exec chmod u=rwX,g=rX,o= {} +
# Regress the actual failure as the daemon identity before loading radiusd.
# Do not substitute a root read check, or weaken the subsequent SQL probe.
if ! su -s /bin/sh -c '
  test -x /opt/etc/raddb &&
  test ! -w /opt/etc/raddb &&
  test -r /opt/etc/raddb/radiusd.conf &&
  test -r /opt/etc/raddb/mods-config/preprocess/huntgroups &&
  test ! -w /opt/etc/raddb/mods-config/preprocess/huntgroups
' freerad; then
  echo 'Native FreeRADIUS configuration permissions preflight failed' >&2
  stat -c '%a %u:%g %n' "$config" "$config/mods-config/preprocess/huntgroups" >&2
  exit 1
fi
echo 'Native configuration readable by non-root daemon and not writable PASS'
# Use upstream's native security settings, not a root-only test.
python3 - <<'PY'
from pathlib import Path
import re
p = Path('/opt/etc/raddb/radiusd.conf')
s = p.read_text()
for name in ('user', 'group'):
    s, n = re.subn(r'(?m)^[ \t]*#[ \t]*' + name + r'[ \t]*=[ \t]*radius[ \t]*$', '\t' + name + ' = freerad', s)
    if n != 1:
        raise SystemExit('Upstream security configuration changed: ' + name)
p.write_text(s)
PY
