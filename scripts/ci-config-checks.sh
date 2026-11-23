#!/usr/bin/env bash
# Discover and run all static/frontend tests. Run in parallel with .NET CI, before Docker.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

node --test tests/js/*.test.mjs
bash -n scripts/*.sh radius/*.sh
python3 -m unittest discover -s tests -p '*checks.py'

# Check every shipped ESM module; do not maintain a hardcoded partial list.
checked=0
while IFS= read -r -d '' file; do
  node --check "$file"
  ((checked += 1))
done < <(find src/RadiusManager.Api/wwwroot -type f -name '*.mjs' -print0)
if ((checked == 0)); then
  echo "No frontend modules were checked; failing closed." >&2
  exit 1
fi
echo "Checked ${checked} frontend ES modules."
