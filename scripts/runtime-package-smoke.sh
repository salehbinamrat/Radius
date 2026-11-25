#!/usr/bin/env bash
# Inspect the actual built API image, not a developer working directory.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${RADIUS_PACKAGE_TEST_ACK:-}" == isolated-ci ]] || {
  echo 'Runtime package check requires isolated CI' >&2; exit 1;
}
container=$(docker compose ps -q api)
[[ -n "$container" ]] || exit 1
image=$(docker inspect --format '{{.Image}}' "$container")
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
docker compose exec -T api sh -ec '
  test -s /app/RadiusManager.Api.dll
  test -s /app/wwwroot/index.html
  test -s /app/wwwroot/app.mjs
  test -s /app/wwwroot/modern/noc-react.mjs
  for tool in node npm python python3; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "Unexpected development tool: $tool" >&2; exit 1
    fi
  done
  test -z "$(dotnet --list-sdks)"
  test ! -d /app/frontend
  test ! -d /app/tests
  unwanted=$(find /app \( -name node_modules -o -name "*.tsx" -o -name "*.ts" -o -name "*.mts" -o -name "*.cs" -o -name "*.py" -o -name "*.csproj" -o -name ".env" -o -name ".env.*" -o -name "*.pfx" -o -name "*.p12" -o -name "*.key" \) -print)
  test -z "$unwanted" || { echo "Unexpected development or secret file in API image" >&2; exit 1; }
'
docker image inspect --format 'API image {{.Id}} uncompressed bytes={{.Size}}' "$image"
echo 'API runtime-only package acceptance PASS'
