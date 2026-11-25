#!/usr/bin/env bash
# Discover and run all static/frontend tests. Run in parallel with .NET CI, before Docker.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash scripts/check-source-syntax.sh
node --test tests/js/*.test.mjs
python3 -m unittest discover -s tests -p '*checks.py'
