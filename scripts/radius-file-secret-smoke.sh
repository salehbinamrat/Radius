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
  -e RADIUS_CLIENT_CIDR=10.255.70.0/24 \
  -v "$RADIUS_HTTPS_SECRET_DIR/radius-secret:/run/radius-secrets/radius-secret:ro" \
  schema-init -ec '
    [[ -z "${DB_PASSWORD:-}" && -z "${RADIUS_SECRET:-}" ]]
    umask 077
    log=$(mktemp)
    wrong=$(mktemp)
    pid=""
    cleanup() {
      if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
      rm -f -- "$log" "$wrong"
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
    test "$(stat -c %a /etc/freeradius/3.0/clients.conf)" = 640
    test "$(stat -c %a /etc/freeradius/3.0/mods-available/sql)" = 640
  '
echo "File-only FreeRADIUS configuration, authenticated Status-Server and negative checks PASS"
