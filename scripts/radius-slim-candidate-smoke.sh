#!/usr/bin/env bash
# Measure and exercise a distinct clean-image candidate; retain current deployment.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${RADIUS_SLIM_TEST_ACK:-}" == isolated-ci ]] || exit 1
legacy=$(docker inspect --format '{{.Image}}' "$(docker compose ps -q radius)")
[[ "$legacy" =~ ^sha256:[a-f0-9]{64}$ ]]
target_tag=radius-slim-candidate:ci
[[ -z "$(docker image ls -q "$target_tag")" ]]
db=$(docker inspect --format '{{.Image}}' "$(docker compose ps -q db)")
api=$(docker inspect --format '{{.Image}}' "$(docker compose ps -q api)")
work="$RUNNER_TEMP/radius-prepared-images"
(cd "$work" && sha256sum --check --strict --status SHA256SUMS)
mapfile -t prepared <"$work/image-ids.txt"
[[ "${#prepared[@]}" == 3 && "${prepared[0]}" == "$db" && "${prepared[1]}" == "$api" ]]
[[ "$(cat "$work/compatible-image-id.txt")" == "$legacy" ]]
candidate="${prepared[2]}"
[[ "$candidate" =~ ^sha256:[a-f0-9]{64}$ && "$candidate" != "$legacy" ]]
[[ "$(docker image inspect --format '{{.Id}}' "$candidate")" == "$candidate" ]]
docker tag "$candidate" "$target_tag"
reports="$RUNNER_TEMP/radius-security-reports"
mkdir -p "$reports"
# Retain the exact source preparation manifest with the security evidence.
for file in platform.txt compatible-image-id.txt image-ids.txt SHA256SUMS; do
  mkdir -p "$reports/source-prepared"
  cp -- "$work/$file" "$reports/source-prepared/$file"
done
(cd "$reports/source-prepared" && sha256sum --check --strict --status SHA256SUMS)
docker image inspect "$legacy" "$candidate" >"$reports/radius-slim-image-inspect.json"
# Inspect only clean disposable containers with no network, credentials or volumes.
read_image() { docker run --rm --pull never --network none --entrypoint sh "$1" -ec "$2"; }
read_image "$legacy" 'apk info -v | sort' >"$reports/radius-slim-legacy-packages.txt"
read_image "$candidate" 'apk info -v | sort' >"$reports/radius-slim-packages.txt"
read_image "$candidate" 'cat /opt/share/radius-build/runtime-packages' >"$reports/radius-slim-build-packages.txt"
cmp "$reports/radius-slim-packages.txt" "$reports/radius-slim-build-packages.txt"
read_image "$legacy" 'sha256sum /opt/sbin/radiusd /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql; cat /opt/share/radius-build/revision /opt/share/radius-build/verified-fixes' >"$reports/radius-slim-legacy-source.txt"
read_image "$candidate" 'sha256sum /opt/sbin/radiusd /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql; cat /opt/share/radius-build/revision /opt/share/radius-build/verified-fixes' >"$reports/radius-slim-source.txt"
cmp "$reports/radius-slim-legacy-source.txt" "$reports/radius-slim-source.txt"
read_image "$candidate" 'test ! -e /opt/radius/migrate.py; test ! -e /opt/radius/radius_secret_input.py; test ! -e /usr/local/bin/schema-init.sh; if command -v python3 || command -v python; then exit 1; fi'
python3 scripts/verify-radius-slim-evidence.py "$reports" --preflight
# Full protocol smoke plus the actual user-facing installer on the reduced image.
RADIUS_SLIM_IMAGE_ID="$candidate" CSHARP_STACK_TEST_ACK=isolated-ci \
  bash scripts/csharp-stack-candidate-smoke.sh local-fresh
RADIUS_SLIM_IMAGE_ID="$candidate" CSHARP_LOCAL_INSTALL_TEST_ACK=isolated-ci \
  bash scripts/csharp-local-installer-smoke.sh
printf '%s\n' "$candidate" >"$reports/radius-slim-image-id.txt"
echo 'Python-free RADIUS image full-stack candidate acceptance PASS'
