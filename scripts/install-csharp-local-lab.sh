#!/usr/bin/env bash
# Fresh isolated local lab only. Never replace, migrate or delete another stack.
set -euo pipefail
set +x
check_only=0
if [[ "${1:-}" == --check ]]; then
  check_only=1
  shift
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$PWD"
[[ $# == 4 && "${RADIUS_LOCAL_INSTALL_ACK:-}" == local-lab-only ]] || {
  echo 'Usage: RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh /absolute/new-directory DB_IMAGE_ID API_IMAGE_ID RADIUS_IMAGE_ID' >&2
  echo '   or: install-csharp-local-lab.sh /absolute/new-directory --prepared /absolute/prepared-images TRUSTED_MANIFEST_SHA256' >&2
  echo '   Prefix arguments with --check to validate without installing.' >&2
  exit 2
}
state="$1"; shift
prepared_platform=
[[ "$state" =~ ^/[a-zA-Z0-9_./-]+$ && "$state" == "$(realpath -m -- "$state")" && ! -e "$state" && ! -L "$state" && -d "$(dirname "$state")" ]] || {
  echo 'Use a new canonical absolute directory with an existing parent; refusing overwrite' >&2; exit 2;
}
# A trusted preparation digest binds the exact generated image list.
# Keep the existing explicit-ID interface for verified offline bundles and
# compatibility tests. Never silently fall back after a manifest failure.
if [[ "$1" == --prepared ]]; then
  prepared="$2"; trusted="$3"
  [[ "${RADIUS_LOCAL_RUNTIME:-slim}" == slim &&
     "$trusted" =~ ^[a-f0-9]{64}$ &&
     "$prepared" =~ ^/[a-zA-Z0-9_./-]+$ &&
     "$prepared" == "$(realpath -- "$prepared")" && -d "$prepared" ]] || {
    echo 'Invalid prepared image directory, digest or runtime' >&2; exit 2;
  }
  # Fixed allowlist; do not follow manifest-provided paths. Copy once to a
  # private temporary directory, then validate and consume the same bytes.
  umask 077
  snapshot="$(mktemp -d)"
  trap 'rm -f -- "$snapshot/platform.txt" "$snapshot/compatible-image-id.txt" "$snapshot/image-ids.txt" "$snapshot/SHA256SUMS"; rmdir -- "$snapshot"' EXIT
  for file in platform.txt compatible-image-id.txt image-ids.txt SHA256SUMS; do
    [[ -f "$prepared/$file" && ! -L "$prepared/$file" ]] || {
      echo 'Missing regular prepared image manifest input' >&2; exit 2;
    }
    cp -- "$prepared/$file" "$snapshot/$file"
  done
  if ! (cd "$snapshot" &&
        [[ "$(sha256sum SHA256SUMS | cut -d ' ' -f1)" == "$trusted" ]] &&
        sha256sum platform.txt compatible-image-id.txt image-ids.txt | cmp -s -- SHA256SUMS -); then
    echo 'Prepared image manifest integrity check failed' >&2; exit 2
  fi
  mapfile -t prepared_ids <"$snapshot/image-ids.txt"
  prepared_platform="$(cat "$snapshot/platform.txt")"
  compatible_id="$(cat "$snapshot/compatible-image-id.txt")"
  [[ "${#prepared_ids[@]}" == 3 &&
     "$compatible_id" =~ ^sha256:[a-f0-9]{64}$ &&
     "$compatible_id" != "${prepared_ids[0]}" &&
     "$compatible_id" != "${prepared_ids[1]}" &&
     "$compatible_id" != "${prepared_ids[2]}" &&
     ( "$prepared_platform" == linux/amd64 || "$prepared_platform" == linux/arm64 ) ]] || {
    echo 'Invalid prepared image roles or platform' >&2; exit 2;
  }
  set -- "${prepared_ids[@]}"
  rm -f -- "$snapshot/platform.txt" "$snapshot/compatible-image-id.txt" "$snapshot/image-ids.txt" "$snapshot/SHA256SUMS"
  rmdir -- "$snapshot"
  trap - EXIT
  echo 'Trusted prepared image manifest verified'
fi
# flock is provided by util-linux on Ubuntu/Debian.
# Validate host tools before any Docker operation. The installed
# manager also requires Bash associative arrays and GNU file utilities.
[[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 3 ) ]] || {
  echo 'Bash 4.3 or newer is required' >&2; exit 2;
}
for command in docker flock openssl sha256sum curl realpath dirname mktemp cp cmp cut cat rm rmdir chmod stat seq sleep grep df; do
  command -v "$command" >/dev/null || { echo "Missing local installation prerequisite: $command" >&2; exit 2; }
done
parent="$(dirname "$state")"
[[ -w "$parent" && -x "$parent" ]] || {
  echo 'Installation parent is not writable and searchable' >&2; exit 2;
}
# Fixed local socket; no remote Docker context or inherited Compose overrides.
local_docker() { env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock "$@"; }
for id in "$@"; do
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Exact local image IDs required' >&2; exit 2; }
done
db_id="$1"; api_id="$2"; radius_id="$3"
[[ "$db_id" != "$api_id" && "$db_id" != "$radius_id" && "$api_id" != "$radius_id" ]] || {
  echo 'Distinct DB, API and RADIUS image IDs required' >&2; exit 2;
}
# No emulation or cross-platform fallback. Check the actual local Docker daemon.
platform="$(local_docker info --format '{{.OSType}}/{{.Architecture}}')"
case "$platform" in
  linux/x86_64|linux/amd64) platform=linux/amd64 ;;
  linux/aarch64|linux/arm64) platform=linux/arm64 ;;
  *) echo 'Unsupported local Docker platform' >&2; exit 2 ;;
esac
if [[ -n "${prepared_platform:-}" && "$prepared_platform" != "$platform" ]]; then
  echo 'Prepared image manifest platform mismatch' >&2; exit 2
fi
for id in "$@"; do
  actual="$(local_docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$id" 2>/dev/null)" || {
    echo 'Required image is not available locally; no download attempted' >&2; exit 2;
  }
  [[ "$actual" == "$id $platform" ]] || {
    echo 'Local image identity or platform mismatch' >&2; exit 2;
  }
done
local_docker compose version >/dev/null
runtime="${RADIUS_LOCAL_RUNTIME:-slim}"
[[ "$runtime" == compatible || "$runtime" == slim ]] || {
  echo 'Expected compatible or slim local runtime' >&2; exit 2;
}
if [[ "$runtime" == slim ]]; then
  # Inspect the actual clean image before creating any project resources.
  if local_docker run --rm --pull never --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges=true --entrypoint sh "$radius_id" -ec '
        if command -v python3 || command -v python; then exit 42; fi
        if ! (test ! -e /opt/radius/migrate.py &&
              test ! -e /opt/radius/radius_secret_input.py &&
              test ! -e /usr/local/bin/schema-init.sh &&
              test -x /usr/local/bin/start.sh &&
              test -x /usr/local/bin/radius-health-probe.sh &&
              test -s /opt/radius/radius_secret_input.sh); then exit 42; fi
      ' >/dev/null; then
    :
  else
    probe_status=$?
    if [[ "$probe_status" == 42 ]]; then
      echo 'Slim runtime requires the Python-free RADIUS image' >&2
    else
      echo "Unable to execute local RADIUS image validation (exit $probe_status)" >&2
    fi
    exit 2
  fi
fi
# A successful image lookup does not prove a non-root executable can run
# after image import. Use the exact DB image, no network or persistent data.
# --version makes the upstream entrypoint skip initialization.
if ! local_docker run --rm --pull never --network none --read-only \
    --entrypoint /bin/sh "$db_id" -ec '
      stat -c "%a %u:%g %n" / /usr /usr/local /usr/local/bin /usr/local/bin/docker-entrypoint.sh
      test "$(id -u postgres)" != 0
      gosu postgres /usr/local/bin/docker-entrypoint.sh postgres --version
    '; then
  echo 'Local PostgreSQL non-root execution preflight failed; inspect runtime permissions' >&2
  exit 2
fi
echo 'Local PostgreSQL non-root entrypoint preflight PASS'
# Verify the exact API image under its configured non-root runtime user,
# without starting the server, opening ports, or mounting application data.
if ! local_docker run --rm --pull never --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges=true --entrypoint /bin/sh "$api_id" -ec '
      test "$(id -u)" != 0
      test -s /app/RadiusManager.Api.dll
      test -s /app/RadiusManager.Api.runtimeconfig.json
      test -s /app/wwwroot/index.html
      test -s /app/wwwroot/modern/noc-react.mjs
      test -z "$(dotnet --list-sdks)"
      dotnet --list-runtimes | grep -Eq "^Microsoft[.]AspNetCore[.]App 10[.]"
      dotnet --list-runtimes | grep -Eq "^Microsoft[.]NETCore[.]App 10[.]"
      for tool in python python3 node npm; do
        if command -v "$tool" >/dev/null 2>&1; then exit 1; fi
      done
    '; then
  echo 'Local API non-root .NET 10 runtime preflight failed; verify image role and platform' >&2
  exit 2
fi
echo 'Local API non-root .NET 10 runtime preflight PASS'
if [[ "$check_only" == 1 ]]; then
  # Report capacity without inventing a hardware-sizing guarantee.
  printf 'Local Docker platform: %s\n' "$platform"
  local_docker compose version
  local_docker info --format 'Docker server: {{.ServerVersion}}; storage: {{.Driver}}; CPUs: {{.NCPU}}; memory bytes: {{.MemTotal}}'
  df -Pk -- "$parent"
  echo 'Local installation preflight PASS (no installation created)'
  exit 0
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
stack() {
  local_docker compose --project-directory "$state" --env-file "$state/stack.env" -p "$project" \
    -f "$state/compose/csharp-stack-candidate.compose.yaml" -f "$state/compose/csharp-stack-local.compose.yaml" "$@"
}
stack config --quiet
# Start only the newly created database. Mark only an empty application baseline.
stack up -d --pull never --no-build --wait db
sql() { stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius "$@"; }
[[ "$(sql -c "SELECT to_regclass('public.app_plans') IS NOT NULL AND to_regclass('public.radcheck') IS NULL AND to_regclass('public.app_schema_migrations') IS NULL AND (SELECT shobj_description(oid,'pg_database') IS NULL FROM pg_database WHERE datname=current_database())")" == t ]]
sql -v marker="radius-csharp-local:$project" <<'SQL'
COMMENT ON DATABASE radius IS :'marker';
SQL
stack up -d --pull never --no-build api radius
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
# Pin the exact installed container identities and the immutable migration ledger.
for svc in db api radius schema-init; do
  container="$(stack ps -aq "$svc")"
  [[ -n "$container" && "$container" != *$'\n'* ]]
  container_id="$(local_docker inspect --format '{{.Id}}' "$container")"
  [[ "$container_id" =~ ^[a-f0-9]{64}$ ]]
  printf '%s %s\n' "$svc" "$container_id"
done >"$state/container-identities.txt"
sql -c "SELECT row_to_json(m)::text FROM app_schema_migrations m ORDER BY version" | sha256sum | cut -d ' ' -f1 >"$state/ledger.sha256"
(cd "$state" && sha256sum project-id runtime-profile image-identities.txt stack.env db-password \
  bundle/SHA256SUMS compose/SHA256SUMS manage.sh container-identities.txt ledger.sha256 > installation.sha256)
printf '%s\n' "http://$addr" >"$state/api-url"
printf '%s\n' 'C# local laboratory installation PASS'
printf 'Management URL: http://%s\nPrivate configuration: %s/stack.env\n' "$addr" "$state"
