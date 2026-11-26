#!/usr/bin/env bash
# Generate the local laboratory configuration without Python or a partial file.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
existing() {
  [[ ! -L .env && -f .env ]]
}
if [[ -e .env || -L .env ]]; then
  existing || { echo 'Refusing non-regular .env path' >&2; exit 1; }
  echo 'Existing .env not overwritten.'
  exit 0
fi
[[ -f .env.example && ! -L .env.example ]] || {
  echo 'Missing regular .env.example template' >&2; exit 1;
}
command -v openssl >/dev/null || { echo 'OpenSSL is required for local setup' >&2; exit 1; }
umask 077
tmp=$(mktemp -d .env.setup.XXXXXXXX)
trap 'rm -f -- "$tmp/.env"; rmdir -- "$tmp"' EXIT
declare -A seen=()
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    DB_PASSWORD=*|RADIUS_SECRET=*|ADMIN_PASSWORD=*)
      key=${line%%=*}
      [[ "$line" == "$key=CHANGE_ME_GENERATE_WITH_SETUP" && -z "${seen[$key]:-}" ]] || {
        echo 'Invalid or duplicate secret placeholder in setup template' >&2; exit 1;
      }
      value=$(openssl rand -hex 24)
      [[ "$value" =~ ^[a-f0-9]{48}$ ]] || {
        echo 'Invalid secret generator output' >&2; exit 1;
      }
      printf '%s=%s\n' "$key" "$value"
      unset value
      seen[$key]=1
      ;;
    *)
      [[ "$line" != *CHANGE_ME_GENERATE_WITH_SETUP* ]] || {
        echo 'Unexpected secret placeholder in setup template' >&2; exit 1;
      }
      printf '%s\n' "$line"
      ;;
  esac
done < .env.example > "$tmp/.env"
[[ ${#seen[@]} == 3 ]] || { echo 'Missing required secret placeholder' >&2; exit 1; }
chmod 600 "$tmp/.env"
# Atomic, exclusive publication on the same filesystem. No overwrite or
# partially written .env, even if two setup processes race.
if ln -T -- "$tmp/.env" .env 2>/dev/null; then
  echo 'Created .env with random secrets. Store it securely; do NOT commit it.'
elif existing; then
  echo 'Existing .env not overwritten.'
else
  echo 'Unable to publish local configuration safely' >&2
  exit 1
fi
echo 'Read README_AR.md and run: docker compose up -d --build'
