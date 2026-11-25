#!/usr/bin/env bash
# Fresh isolated local lab only. Never replace, migrate or delete another stack.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$PWD"
[[ $# == 4 && "${RADIUS_LOCAL_INSTALL_ACK:-}" == local-lab-only ]] || {
  echo 'Usage: RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh /absolute/new-directory DB_IMAGE_ID API_IMAGE_ID RADIUS_IMAGE_ID' >&2
  exit 2
}
state="$1"; shift
[[ "$state" =~ ^/[a-zA-Z0-9_./-]+$ && "$state" == "$(realpath -m -- "$state")" && ! -e "$state" && ! -L "$state" && -d "$(dirname "$state")" ]] || {
  echo 'Use a new canonical absolute directory with an existing parent; refusing overwrite' >&2; exit 2;
}
# Fixed local socket; no remote Docker context or inherited Compose overrides.
local_docker() { env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock "$@"; }
for id in "$@"; do
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Exact local image IDs required' >&2; exit 2; }
done
for id in "$@"; do
  [[ "$(local_docker image inspect --format '{{.Id}}' "$id")" == "$id" ]] || exit 1
done
db_id="$1"; api_id="$2"; radius_id="$3"
runtime="${RADIUS_LOCAL_RUNTIME:-slim}"
[[ "$runtime" == compatible || "$runtime" == slim ]] || {
  echo 'Expected compatible or slim local runtime' >&2; exit 2;
}
if [[ "$runtime" == slim ]]; then
  # Inspect the actual clean image before creating any project resources.
  if ! local_docker run --rm --pull never --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges:true --entrypoint sh "$radius_id" -ec '
        if command -v python3 || command -v python; then exit 1; fi
        test ! -e /opt/radius/migrate.py
        test ! -e /opt/radius/radius_secret_input.py
        test ! -e /usr/local/bin/schema-init.sh
        test -x /usr/local/bin/start.sh
        test -x /usr/local/bin/radius-health-probe.sh
        test -s /opt/radius/radius_secret_input.sh
      ' >/dev/null 2>&1; then
    echo 'Slim runtime requires the Python-free RADIUS image' >&2; exit 2
  fi
fi
project="radiuscsharp$(openssl rand -hex 4)"
[[ "$project" =~ ^radiuscsharp[a-f0-9]{8}$ ]]
[[ -z "$(local_docker ps -aq --filter "label=com.docker.compose.project=$project")" ]]
[[ -z "$(local_docker volume ls -q --filter "label=com.docker.compose.project=$project")" ]]
[[ -z "$(local_docker network ls -q --filter "label=com.docker.compose.project=$project")" ]]
for svc in db api radius; do
  [[ -z "$(local_docker image ls -q "radius-local-$svc:$project")" ]]
done
umask 077
mkdir -- "$state"
# On failure preserve diagnostics and data. No automatic deletion or fallback.
trap 'echo "Local installation failed; retained state at $state for inspection" >&2' ERR
printf '%s\n' "$project" >"$state/project-id"
printf '%s\n' "$runtime" >"$state/runtime-profile"
for svc in db api radius; do
  case "$svc" in db) id="$db_id";; api) id="$api_id";; radius) id="$radius_id";; esac
  local_docker tag "$id" "radius-local-$svc:$project"
done
env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST=unix:///var/run/docker.sock \
  bash scripts/export-csharp-init-bundle.sh "$radius_id" "$state/bundle"
(cd "$state/bundle" && sha256sum --check --strict --status SHA256SUMS)
manifest="$(sha256sum "$state/bundle/SHA256SUMS" | cut -d ' ' -f1)"
# Freeze the two tested Compose files with the installed instance. All mounts
# now refer to its private state or named volumes, not the source checkout.
mkdir -- "$state/compose"
cp -- "$root/tests/csharp-stack-candidate.compose.yaml" "$state/compose/"
cp -- "$root/tests/csharp-stack-local.compose.yaml" "$state/compose/"
(cd "$state/compose" && sha256sum csharp-stack-candidate.compose.yaml csharp-stack-local.compose.yaml > SHA256SUMS)
db_password="$(openssl rand -hex 24)"
admin_password="$(openssl rand -hex 24)"
radius_secret="$(openssl rand -hex 24)"
printf '%s\n' "$db_password" >"$state/db-password"
# The parent directory is 0700; the single file is readable by the non-root initializer.
chmod 444 "$state/db-password"
{
  printf 'CSHARP_STACK_ID=%s\n' "$project"
  printf 'CSHARP_DB_IMAGE=radius-local-db:%s\n' "$project"
  printf 'CSHARP_API_IMAGE=radius-local-api:%s\n' "$project"
  printf 'CSHARP_RADIUS_IMAGE=radius-local-radius:%s\n' "$project"
  printf 'CSHARP_DB_PASSWORD=%s\nCSHARP_ADMIN_PASSWORD=%s\nCSHARP_RADIUS_SECRET=%s\n' "$db_password" "$admin_password" "$radius_secret"
  printf 'CSHARP_DB_PASSWORD_FILE=%s/db-password\nCSHARP_BUNDLE_DIR=%s/bundle\n' "$state" "$state"
  printf 'CSHARP_MANIFEST_SHA256=%s\n' "$manifest"
} >"$state/stack.env"
unset db_password admin_password radius_secret
# Save exact expected image IDs separately for future verification.
printf 'db %s\napi %s\nradius %s\n' "$db_id" "$api_id" "$radius_id" >"$state/image-identities.txt"
cp -- "$root/scripts/manage-csharp-local-lab.sh" "$state/manage.sh"
chmod 700 "$state/manage.sh"
(cd "$state" && sha256sum project-id runtime-profile image-identities.txt stack.env db-password \
  bundle/SHA256SUMS compose/SHA256SUMS manage.sh > installation.sha256)
stack() {
  local_docker compose --project-directory "$state" --env-file "$state/stack.env" -p "$project" \
    -f "$state/compose/csharp-stack-candidate.compose.yaml" -f "$state/compose/csharp-stack-local.compose.yaml" "$@"
}
stack config --quiet
# Start only the newly created database. Mark only an empty application baseline.
stack up -d --wait db
sql() { stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"; }
[[ "$(sql -c "SELECT to_regclass('public.app_plans') IS NOT NULL AND to_regclass('public.radcheck') IS NULL AND to_regclass('public.app_schema_migrations') IS NULL AND (SELECT shobj_description(oid,'pg_database') IS NULL FROM pg_database WHERE datname=current_database())")" == t ]]
sql -v marker="radius-csharp-local:$project" <<'SQL'
COMMENT ON DATABASE radius IS :'marker';
SQL
stack up -d api radius
init="$(stack ps -aq schema-init)"
[[ -n "$init" && "$(local_docker inspect --format '{{.State.ExitCode}}' "$init")" == 0 ]]
[[ "$(local_docker inspect --format '{{.Image}}' "$init")" == "$api_id" ]]
stack logs --no-color schema-init | grep -F 'C# migration execution PASS: 10 immutable versions (isolated local lab)'
for svc in db api radius; do
  case "$svc" in db) id="$db_id";; api) id="$api_id";; radius) id="$radius_id";; esac
  [[ "$(local_docker inspect --format '{{.Image}}' "$(stack ps -q "$svc")")" == "$id" ]]
done
[[ "$(sql -c 'SELECT count(*) FROM app_schema_migrations')" == 10 ]]
addr="$(stack port api 8080)"
[[ "$addr" =~ ^127\.0\.0\.1:[0-9]+$ ]]
ready=0
for attempt in $(seq 1 30); do
  if curl --silent --fail "http://$addr/api/health/ready" >/dev/null &&
     [[ "$(local_docker inspect --format '{{.State.Health.Status}}' "$(stack ps -q radius)")" == healthy ]]; then
    ready=1; break
  fi
  sleep 2
done
[[ "$ready" == 1 ]]
printf '%s\n' "http://$addr" >"$state/api-url"
printf '%s\n' 'C# local laboratory installation PASS'
printf 'Management URL: http://%s\nPrivate configuration: %s/stack.env\n' "$addr" "$state"
