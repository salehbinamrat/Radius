#!/usr/bin/env bash
# Prepare trusted local laboratory images without starting a legacy stack.
set -euo pipefail
set +x
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${RADIUS_LOCAL_BUILD_ACK:-}" == local-lab-only && ( $# == 1 || $# == 4 ) ]] || {
  echo 'Usage: RADIUS_LOCAL_BUILD_ACK=local-lab-only bash scripts/prepare-csharp-local-images.sh /absolute/new-output [DB_ID API_ID LEGACY_RADIUS_ID]' >&2; exit 2;
}
destination="$1"; shift
[[ "$destination" =~ ^/[a-zA-Z0-9_./-]+$ && "$destination" == "$(realpath -m -- "$destination")" &&
   ! -e "$destination" && ! -L "$destination" && -d "$(dirname "$destination")" ]] || {
  echo 'Use a new canonical output directory; refusing overwrite' >&2; exit 2;
}
for command in docker openssl sha256sum; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 2; }
done
local_docker() { env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock "$@"; }
case "$(local_docker info --format '{{.OSType}}/{{.Architecture}}')" in
  linux/x86_64|linux/amd64) platform=linux/amd64 ;;
  linux/aarch64|linux/arm64) platform=linux/arm64 ;;
  *) echo 'Unsupported local Docker platform' >&2; exit 2 ;;
esac
image_id() {
  local id
  id="$(local_docker image inspect --format '{{.Id}}' "$1")"
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]]
  printf '%s\n' "$id"
}
verify_ids() {
  [[ $# == 3 && "$1" != "$2" && "$1" != "$3" && "$2" != "$3" ]] || return 1
  local id
  for id in "$@"; do
    [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    [[ "$(local_docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$id")" == "$id $platform" ]] || return 1
  done
}
# Reuse only exact local images explicitly supplied by the operator.
if [[ $# == 3 ]]; then
  verify_ids "$@" || { echo 'Invalid, missing, duplicate or incompatible local images' >&2; exit 2; }
fi
token="$(openssl rand -hex 8)"
[[ "$token" =~ ^[a-f0-9]{16}$ ]]
db_tag="radius-prepared-db:$token"
api_tag="radius-prepared-api:$token"
legacy_tag="radius-prepared-compatible:$token"
slim_tag="radius-prepared-slim:$token"
for tag in "$db_tag" "$api_tag" "$legacy_tag" "$slim_tag"; do
  [[ -z "$(local_docker image ls -q "$tag")" ]] || exit 2
done
umask 077
mkdir -- "$destination"
trap 'echo "Image preparation failed; retained output and any built images for inspection" >&2' ERR
if [[ $# == 0 ]]; then
  # Use the same pinned recipes as the existing Compose integration build.
  # Building can require internet access; installation from these images does not.
  local_docker build --pull=false -f tests/postgres-alpine-remediation.Dockerfile -t "$db_tag" tests
  local_docker build --pull=false -f src/RadiusManager.Api/Dockerfile -t "$api_tag" src/RadiusManager.Api
  local_docker build --pull=false -f radius/Dockerfile -t "$legacy_tag" radius
  db="$(image_id "$db_tag")"
  api="$(image_id "$api_tag")"
  legacy="$(image_id "$legacy_tag")"
else
  db="$1"; api="$2"; legacy="$3"
  # Retain a separate tag for the exact source of the reduced image.
  local_docker tag "$legacy" "$legacy_tag"
fi
verify_ids "$db" "$api" "$legacy"
local_docker build --pull=false --network none --build-arg LEGACY_IMAGE="$legacy_tag" \
  -f tests/radius-slim-candidate.Dockerfile -t "$slim_tag" tests
slim="$(image_id "$slim_tag")"
[[ "$slim" != "$legacy" ]]
verify_ids "$db" "$api" "$slim"
local_docker run --rm --pull never --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges=true --entrypoint sh "$slim" -ec '
    ! command -v python3 && ! command -v python &&
    test ! -e /opt/radius/migrate.py &&
    test ! -e /opt/radius/radius_secret_input.py &&
    test ! -e /usr/local/bin/schema-init.sh &&
    test -x /usr/local/bin/start.sh &&
    test -s /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql
  '
# No .env, running services or database volumes are needed.
printf '%s\n' "$platform" >"$destination/platform.txt"
printf '%s\n' "$legacy" >"$destination/compatible-image-id.txt"
printf '%s\n' "$db" "$api" "$slim" >"$destination/image-ids.txt"
(cd "$destination" && sha256sum platform.txt compatible-image-id.txt image-ids.txt >SHA256SUMS)
echo 'C# local image preparation PASS (laboratory only)'
echo "Prepared image IDs: $destination/image-ids.txt"
