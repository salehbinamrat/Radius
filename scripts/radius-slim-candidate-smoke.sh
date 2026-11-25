#!/usr/bin/env bash
# Measure and exercise a distinct clean-image candidate; retain current deployment.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${CI:-}" == true && "${RADIUS_SLIM_TEST_ACK:-}" == isolated-ci ]] || exit 1
legacy=$(docker inspect --format '{{.Image}}' "$(docker compose ps -q radius)")
[[ "$legacy" =~ ^sha256:[a-f0-9]{64}$ ]]
source_tag=radius-slim-source:ci
target_tag=radius-slim-candidate:ci
[[ -z "$(docker image ls -q "$source_tag")" && -z "$(docker image ls -q "$target_tag")" ]]
docker tag "$legacy" "$source_tag"
trap 'docker image rm "$source_tag" >/dev/null' EXIT
docker build --pull=false --network none --build-arg LEGACY_IMAGE="$source_tag" \
  -f tests/radius-slim-candidate.Dockerfile -t "$target_tag" tests
candidate=$(docker image inspect --format '{{.Id}}' "$target_tag")
[[ "$candidate" =~ ^sha256:[a-f0-9]{64}$ && "$candidate" != "$legacy" ]]
reports="$RUNNER_TEMP/radius-security-reports"
mkdir -p "$reports"
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
# Same actual C# installer plus protocol smoke on the reduced image, not the legacy image.
RADIUS_SLIM_IMAGE_ID="$candidate" CSHARP_STACK_TEST_ACK=isolated-ci \
  bash scripts/csharp-stack-candidate-smoke.sh local-fresh
printf '%s\n' "$candidate" >"$reports/radius-slim-image-id.txt"
echo 'Python-free RADIUS image full-stack candidate acceptance PASS'
