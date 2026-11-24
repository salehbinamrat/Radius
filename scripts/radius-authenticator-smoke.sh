#!/usr/bin/env bash
# Protocol acceptance on container loopback only, never a production NAS.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_RADIUS_AUTHENTICATOR_ACK:-}" == isolated-ci ]] || {
  echo 'Requires isolated CI acknowledgement' >&2; exit 1;
}
# Verify the actual running source build, not a Debian package listing.
docker compose exec -T radius sh -ec '
  test "$(cat /opt/share/radius-build/revision)" = 00abf778c6c0af0320879c2b1ade9cf252a42506
  radiusd -v 2>&1 | grep -F "git #00abf778c"
  test -s /opt/share/radius-build/verified-fixes
  test "$(awk "/^Uid:/{print \$2}" /proc/1/status)" = "$(id -u freerad)"
  test "$(id -u freerad)" != 0
'
docker compose exec -T radius sh -ec '
  for path in /etc/freeradius/3.0/mods-enabled/eap /etc/freeradius/3.0/sites-enabled/inner-tunnel; do
    test ! -e "$path" && test ! -L "$path" || exit 1
  done
'
# Execute the tested wire helper inside the isolated container, not on a real NAS.
docker compose exec -T radius python3 - < tests/radius-authenticator-wire.py
# Acceptance output includes: signed EAP request rejected
