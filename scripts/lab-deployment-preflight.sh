#!/usr/bin/env bash
# Strictly a local test preflight. No migrations, networking changes or production actions.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ "${LAB_NETWORK_PREFLIGHT_ACK:-}" != "isolated-lab" ]]; then
  echo "Set LAB_NETWORK_PREFLIGHT_ACK=isolated-lab ONLY for your disposable local lab." >&2
  exit 2
fi
[[ -f .env ]] || { echo "Missing private .env; first run scripts/setup.sh" >&2; exit 2; }
docker compose config --format json | python3 scripts/validate_lab_compose.py
