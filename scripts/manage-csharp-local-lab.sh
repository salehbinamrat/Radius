#!/usr/bin/env bash
# Installed-instance management only. Never build, pull, recreate or delete.
set -euo pipefail
set +x
[[ $# == 1 && ( "$1" == status || "$1" == start || "$1" == stop ) ]] || {
  echo 'Usage: bash manage.sh status|start|stop' >&2; exit 2;
}
action="$1"
state="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$state"
[[ "$(stat -c %a .)" == 700 && "$(stat -c %a stack.env)" == 600 ]] || {
  echo 'Private local installation permissions changed' >&2; exit 1;
}
# Integrity against accidental changes; the local state owner is trusted.
if ! sha256sum --check --strict --status installation.sha256 ||
   ! (cd compose && sha256sum --check --strict --status SHA256SUMS) ||
   ! (cd bundle && sha256sum --check --strict --status SHA256SUMS); then
  echo 'Local installation integrity check failed' >&2; exit 1
fi
project="$(cat project-id)"
[[ "$project" =~ ^radiuscsharp[a-f0-9]{8}$ ]]
local_docker() { env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock "$@"; }
stack() {
  local_docker compose --project-directory "$state" --env-file "$state/stack.env" -p "$project" \
    -f "$state/compose/csharp-stack-candidate.compose.yaml" -f "$state/compose/csharp-stack-local.compose.yaml" "$@"
}
# Require all original containers, including the successful one-shot initializer.
# A missing container requires an explicit recovery procedure, never a fresh DB.
declare -A expected
while read -r svc id extra; do
  [[ "$svc" == db || "$svc" == api || "$svc" == radius ]]
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ && -z "$extra" && ! -v expected[$svc] ]]
  expected[$svc]="$id"
done < image-identities.txt
[[ "${#expected[@]}" == 3 ]]
for svc in db api radius schema-init; do
  key="$svc"; [[ "$svc" != schema-init ]] || key=api
  container="$(stack ps -aq "$svc")"
  [[ -n "$container" && "$container" != *$'\n'* ]] || {
    echo 'Original local service container missing; recovery required' >&2; exit 1;
  }
  [[ "$(local_docker inspect --format '{{.Image}}' "$container")" == "${expected[$key]}" &&
     "$(local_docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container")" == "$project" ]] || {
    echo 'Local service identity mismatch' >&2; exit 1;
  }
  if [[ "$svc" == schema-init ]]; then
    [[ "$(local_docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$container")" == 'exited 0' ]] || {
      echo 'Local initializer has not completed successfully' >&2; exit 1;
    }
  fi
done
case "$action" in
  status) stack ps -a ;;
  stop) stack stop api radius; stack stop db ;;
  start)
    stack start db
    ready=0
    for attempt in $(seq 1 30); do
      if stack exec -T db pg_isready -h 127.0.0.1 -U radius -d radius >/dev/null 2>&1; then
        ready=1; break
      fi
      sleep 2
    done
    [[ "$ready" == 1 ]]
    # Existing database marker and migration ledger must still match.
    [[ "$(stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius \
      -c "SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname=current_database()")" == "radius-csharp-local:$project" ]]
    [[ "$(stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius \
      -c 'SELECT count(*) FROM app_schema_migrations')" == 10 ]]
    stack start radius api
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
    printf '%s\n' "http://$addr" > api-url
    printf 'Management URL: http://%s\n' "$addr"
    ;;
esac
