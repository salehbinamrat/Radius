#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ -e .env ]]; then
  echo "Existing .env not overwritten."
  exit 0
fi
umask 077
python3 - <<'PYSETUP'
from pathlib import Path
import secrets
src=Path('.env.example').read_text(encoding='utf-8')
for key in ('DB_PASSWORD','RADIUS_SECRET','ADMIN_PASSWORD'):
    src=src.replace(f'{key}=CHANGE_ME_GENERATE_WITH_SETUP',f'{key}='+secrets.token_hex(24))
Path('.env').write_text(src,encoding='utf-8')
PYSETUP
chmod 600 .env
echo 'Created .env with random secrets. Store it securely; do NOT commit it.'
echo 'Read README_AR.md and run: docker compose up -d --build'
