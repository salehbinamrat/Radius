#!/usr/bin/env bash
# Exercise the actual local installation entry point on the CI Docker host.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${CSHARP_LOCAL_INSTALL_TEST_ACK:-}" == isolated-ci ]] || exit 1
umask 077
tmp=$(mktemp -d)
state="$tmp/install"
project=
cleanup() {
  local status=$?
  if [[ -f "$state/project-id" ]]; then
    project="$(cat "$state/project-id")"
    if [[ "$project" =~ ^radiuscsharp[a-f0-9]{8}$ && -f "$state/stack.env" ]]; then
      stack down -v --remove-orphans >/dev/null 2>&1 || status=1
      for svc in db api radius; do docker image rm "radius-local-$svc:$project" >/dev/null 2>&1 || status=1; done
    else
      status=1
    fi
  fi
  rm -rf -- "$tmp"
  exit "$status"
}
stack() {
  env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock compose --env-file "$state/stack.env" -p "$project" \
    -f tests/csharp-stack-candidate.compose.yaml -f tests/csharp-stack-local.compose.yaml "$@"
}
trap cleanup EXIT
ids=()
for svc in db api radius; do
  ids+=("$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "$svc")")")
done
if RADIUS_LOCAL_INSTALL_ACK= bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}" >"$tmp/refusal.log" 2>&1; then
  echo 'Installer accepted missing authorization' >&2; exit 1
fi
[[ ! -e "$state" ]]
RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}"
project="$(cat "$state/project-id")"
[[ "$(stat -c %a "$state")" == 700 && "$(stat -c %a "$state/stack.env")" == 600 ]]
before="$(sha256sum "$state/stack.env")"
if RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}" >"$tmp/refusal.log" 2>&1; then
  echo 'Installer accepted existing destination' >&2; exit 1
fi
[[ "$(sha256sum "$state/stack.env")" == "$before" ]]
url="$(cat "$state/api-url")"
[[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]
RADIUS_UI_URL="$url" bash scripts/ui-smoke.sh
# Verify a stop/start with the same persistent volume and existing ledger.
db_before="$(stack ps -q db)"
ledger_before="$(stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")"
stack stop api radius
stack up -d api radius
[[ "$(stack ps -q db)" == "$db_before" ]]
[[ "$(stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")" == "$ledger_before" ]]
echo 'Actual local C# installer, overwrite refusal and persistent restart PASS'
