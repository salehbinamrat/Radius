#!/usr/bin/env bash
# Runs only inside the disposable source-candidate container.
set -euo pipefail
umask 077
export PATH="/opt/sbin:/opt/bin:$PATH"
log=$(mktemp)
secret_file=$(mktemp)
pid=
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -f -- "$log" "$secret_file"
}
trap cleanup EXIT
# Only allow generated lab inputs and the existing project's configuration.
[[ "$DB_PASSWORD" =~ ^[a-f0-9]{48}$ && "$RADIUS_SECRET" =~ ^[a-f0-9]{48}$ ]] || exit 1
[[ "$RADIUS_CLIENT_CIDR" == 192.0.2.0/24 ]] || exit 1
[[ -f /opt/etc/raddb/radiusd.conf && -d /opt/radius ]] || exit 1
if ! grep -q '^freerad:' /etc/group; then addgroup -S freerad; fi
if ! id freerad >/dev/null 2>&1; then adduser -S -D -H -G freerad freerad; fi
mkdir -p /etc/freeradius
ln -s /opt/etc/raddb /etc/freeradius/3.0
# A symlink changes argv[0] and upstream derives the config name from it.
# Use the native command with an explicit config name and directory.
test -f /opt/source-command.sh
cp /opt/source-command.sh /usr/local/bin/freeradius
chmod 755 /usr/local/bin/freeradius
mkdir -p /opt/var/run/radiusd /opt/var/log/radius/radacct
chown -R freerad:freerad /opt/var
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
printf '%s\n' "$RADIUS_SECRET" > "$secret_file"
# Execute the application's actual configuration renderer, validator and server.
bash /opt/radius/start.sh > "$log" 2>&1 &
pid=$!
report_failure() {
  echo 'FreeRADIUS native SQL runtime acceptance failed' >&2
  # Print only diagnostic lines, never raw debug output or generated secrets.
  grep -Ei 'failed|error|cannot|permission denied|not found' "$log" |
    python3 -c 'import os,sys
for line in sys.stdin:
    for key in ("DB_PASSWORD","RADIUS_SECRET"):
        line=line.replace(os.environ[key], "[redacted]")
    print(line.rstrip())' | tail -n 35 || true
}
request() {
  printf 'User-Name = "source_probe"\nUser-Password = "%s"\nMessage-Authenticator = 0x00\n' "$1" |
    timeout 5s radclient -x -r 1 -t 2 -S "$secret_file" 127.0.0.1:1812 auth 2>&1
}
ready=0
for _ in $(seq 1 20); do
  if ! kill -0 "$pid" 2>/dev/null; then report_failure; exit 1; fi
  if reply=$(request 'synthetic-source-probe-only') && grep -Eq '^Received Access-Accept([[:space:]]|$)' <<< "$reply"; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || { report_failure; exit 1; }
# Confirm the real process has dropped privileges.
[[ "$(awk '/^Uid:/{print $2}' "/proc/$pid/status")" == "$(id -u freerad)" ]] || { echo 'FreeRADIUS did not drop privileges' >&2; exit 1; }
# A signed request with an incorrect password must be rejected.
reply=$(request 'synthetic-invalid-password') || true
grep -Eq '^Received Access-Reject([[:space:]]|$)' <<< "$reply" || { report_failure; exit 1; }
echo 'Native FreeRADIUS PostgreSQL module: signed PAP accept/reject and non-root process PASS'
