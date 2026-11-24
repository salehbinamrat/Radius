#!/usr/bin/env bash
# CI-only one-off FreeRADIUS server with file-only credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_HTTPS_TEST_ACK:-}" == isolated-ci ]] || exit 1
[[ $# == 2 && "$1" =~ ^radiushttps[a-f0-9]{8}$ && "$2" == tests/admin-https.compose.yaml ]] || exit 1
[[ -n "${RADIUS_HTTPS_SECRET_DIR:-}" && -f "$RADIUS_HTTPS_SECRET_DIR/radius-secret" ]] || exit 1
docker compose -p "$1" -f "$2" run --rm --no-deps \
  --entrypoint bash \
  -e RADIUS_SECRET_FILE=/run/radius-secrets/radius-secret \
  radius-runtime -ec '
    [[ -z "${DB_PASSWORD:-}" && -z "${RADIUS_SECRET:-}" ]]
    [[ "$RADIUS_DB_USER" == radius_runtime && "$DB_PASSWORD_FILE" == /run/radius-secrets/runtime-db-password ]]
    [[ ! -e /run/radius-secrets/db-password ]]
    python3 /opt/radius/runtime-role-probe.py
    umask 077
    log=$(mktemp)
    wrong=$(mktemp)
    pid=""
    cleanup() {
      if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
      rm -f -- "$log" "$wrong" "$log.auth" "$log.acct"
    }
    trap cleanup EXIT
    /usr/local/bin/start.sh >"$log" 2>&1 &
    pid=$!
    for i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || { echo "File-secret RADIUS failed to start" >&2; exit 1; }
      if /usr/local/bin/radius-health-probe.sh; then break; fi
      if (( i == 20 )); then echo "File-secret RADIUS probe failed" >&2; exit 1; fi
      sleep 1
    done
    # Derive a distinct valid hexadecimal secret without printing it.
    python3 - "$wrong" <<'"'"'PY'"'"'
import os,sys
from pathlib import Path
value=Path(os.environ["RADIUS_SECRET_FILE"]).read_text()[:48]
Path(sys.argv[1]).write_text(("b" if value[0]=="a" else "a")+value[1:])
PY
    if RADIUS_SECRET_FILE="$wrong" /usr/local/bin/radius-health-probe.sh; then
      echo "Incorrect mounted secret accepted" >&2; exit 1
    fi
    if RADIUS_SECRET=invalid /usr/local/bin/radius-health-probe.sh; then
      echo "Conflicting secret sources accepted" >&2; exit 1
    fi
    /usr/local/bin/radius-health-probe.sh
    # Exercise actual PAP and accounting with the limited SQL login.
    # Do not print packets, credentials or server logs.
    {
      printf "User-Name = \"lab_00000000d2a1\"\n"
      printf "User-Password = \"%s\"\n" "$(cat /run/radius-secrets/runtime-user-password)"
      printf "NAS-IP-Address = 10.255.70.21\n"
      printf "Message-Authenticator = 0x00\n"
    } | radclient -x -r 1 -t 3 -S "$RADIUS_SECRET_FILE" 127.0.0.1:1812 auth >"$log.auth" 2>&1 || {
      echo "Restricted role PAP transport failed" >&2; exit 1;
    }
    grep -q "Received Access-Accept" "$log.auth" || { echo "Restricted role PAP did not accept valid fixture" >&2; exit 1; }
    # A wrong PAP password must be denied even with the correct shared secret.
    # radclient exit conventions vary; require an explicit Access-Reject packet.
    {
      printf "User-Name = \"lab_00000000d2a1\"\n"
      printf "User-Password = \"invalid-fixture-password\"\n"
      printf "NAS-IP-Address = 10.255.70.21\nMessage-Authenticator = 0x00\n"
    } | radclient -x -r 1 -t 3 -S "$RADIUS_SECRET_FILE" 127.0.0.1:1812 auth >"$log.auth" 2>&1 || true
    grep -q "Received Access-Reject" "$log.auth" || { echo "Restricted role PAP failed to reject incorrect password" >&2; exit 1; }
    echo "Restricted role positive and negative PAP PASS"
    for state in Start Interim-Update Stop; do
      up=0; down=0
      if [[ "$state" == Interim-Update ]]; then up=100; down=200; fi
      if [[ "$state" == Stop ]]; then up=175; down=325; fi
      {
        printf "User-Name = \"lab_00000000d2a1\"\nAcct-Session-Id = \"role-smoke\"\n"
        printf "NAS-IP-Address = 10.255.70.21\nNAS-Port = 5\nAcct-Status-Type = %s\n" "$state"
        printf "Acct-Input-Octets = %s\nAcct-Output-Octets = %s\nAcct-Session-Time = 60\n" "$up" "$down"
      } | radclient -x -r 1 -t 3 -S "$RADIUS_SECRET_FILE" 127.0.0.1:1813 acct >"$log.acct" 2>&1 || {
        echo "Restricted role accounting transport failed: $state" >&2; exit 1;
      }
      grep -q "Received Accounting-Response" "$log.acct" || {
        echo "Restricted role accounting response missing: $state" >&2; exit 1;
      }
    done
    rm -f "$log.auth" "$log.acct"
    test "$(stat -c %a /etc/freeradius/3.0/clients.conf)" = 640
    test "$(stat -c %a /etc/freeradius/3.0/mods-available/sql)" = 640
  '
echo "File-only FreeRADIUS configuration, authenticated Status-Server and negative checks PASS"
