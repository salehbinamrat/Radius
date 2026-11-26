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
  env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock compose --project-directory "$state" --env-file "$state/stack.env" -p "$project" \
    -f "$state/compose/csharp-stack-candidate.compose.yaml" -f "$state/compose/csharp-stack-local.compose.yaml" "$@"
}
trap cleanup EXIT
ids=()
for svc in db api radius; do
  ids+=("$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "$svc")")")
done
runtime=compatible
if [[ -n "${RADIUS_SLIM_IMAGE_ID:-}" ]]; then
  [[ "$RADIUS_SLIM_IMAGE_ID" =~ ^sha256:[a-f0-9]{64}$ ]]
  # The original image must be refused by the explicitly slim-only installer.
  if env -u RADIUS_LOCAL_RUNTIME RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}" >"$tmp/refusal.log" 2>&1; then
    echo 'Slim installer accepted legacy runtime' >&2; exit 1
  fi
  grep -Fxq 'Slim runtime requires the Python-free RADIUS image' "$tmp/refusal.log"
  [[ ! -e "$state" ]]
  ids[2]="$RADIUS_SLIM_IMAGE_ID"
  runtime=slim
fi
# Compatible is now an explicit fallback; the slim test exercises the default.
if [[ "$runtime" == slim ]]; then
  unset RADIUS_LOCAL_RUNTIME
else
  export RADIUS_LOCAL_RUNTIME=compatible
fi
if RADIUS_LOCAL_INSTALL_ACK= bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}" >"$tmp/refusal.log" 2>&1; then
  echo 'Installer accepted missing authorization' >&2; exit 1
fi
[[ ! -e "$state" ]]
# Missing or duplicated images must be rejected before creating the installation.
missing="sha256:$(printf '%064d' 0)"
if RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" "${ids[0]}" "${ids[1]}" "$missing" >"$tmp/refusal.log" 2>&1; then
  echo 'Installer accepted missing local image' >&2; exit 1
fi
grep -Fxq 'Required image is not available locally; no download attempted' "$tmp/refusal.log"
[[ ! -e "$state" ]]
if RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" "${ids[0]}" "${ids[0]}" "${ids[2]}" >"$tmp/refusal.log" 2>&1; then
  echo 'Installer accepted duplicate role images' >&2; exit 1
fi
grep -Fxq 'Distinct DB, API and RADIUS image IDs required' "$tmp/refusal.log"
[[ ! -e "$state" ]]
if [[ "$runtime" == slim ]]; then
  # Exercise the documented source-prepared installer directly, before the
  # independent offline package path. Both use the same immutable IDs.
  prepared="$RUNNER_TEMP/radius-prepared-images"
  trusted=$(sha256sum "$prepared/SHA256SUMS" | cut -d ' ' -f1)
  legacy=$(cat "$prepared/compatible-image-id.txt")
  if RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh --check "$state" "${ids[0]}" "$legacy" "${ids[2]}" >"$tmp/refusal.log" 2>&1; then
    echo 'Preflight accepted a non-API image in the API role' >&2; exit 1
  fi
  grep -Fxq 'Local API non-root .NET 10 runtime preflight failed; verify image role and platform' "$tmp/refusal.log"
  [[ ! -e "$state" ]]
  # Snapshot the CI project resource set, excluding temporary probe containers
  # which are removed on exit. The preflight must leave no new resources.
  resources() {
    docker ps -aq --no-trunc | sort
    docker volume ls -q | sort
    docker network ls -q --no-trunc | sort
    docker image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | sort
  }
  before_resources=$(resources)
  RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh --check "$state" --prepared "$prepared" "$trusted"
  [[ ! -e "$state" && "$(resources)" == "$before_resources" ]]
  echo 'Prepared image host preflight left Docker resources and destination unchanged PASS'
  RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" --prepared "$prepared" "$trusted"
  project="$(cat "$state/project-id")"
  [[ "$project" =~ ^radiuscsharp[a-f0-9]{8}$ && "$(cat "$state/runtime-profile")" == slim ]]
  [[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q db)")" == "${ids[0]}" ]]
  [[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q api)")" == "${ids[1]}" ]]
  [[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q radius)")" == "${ids[2]}" ]]
  (cd "$state" && bash manage.sh status) >/dev/null
  echo 'Direct prepared manifest installation and exact image identities PASS'
  # Remove only this disposable CI project; preserve the source preparation.
  stack down -v --remove-orphans
  for svc in db api radius; do docker image rm "radius-local-$svc:$project" >/dev/null; done
  state="$tmp/offline-install"
  project=
  package="$tmp/package"
  RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/offline-csharp-local-lab.sh export "$package" "${ids[@]}"
  digest="$(sha256sum "$package/SHA256SUMS" | cut -d ' ' -f1)"
  [[ ! -e "$package/.env" && ! -e "$package/.git" && ! -e "$package/stack.env" ]]
  # Tamper a small file and require refusal without creating any state.
  cp "$package/platform.txt" "$tmp/original-platform"
  printf 'tamper\n' >>"$package/platform.txt"
  if RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash "$package/scripts/offline-csharp-local-lab.sh" install "$state" "$digest" >"$tmp/refusal.log" 2>&1; then
    echo 'Offline installer accepted modified bundle' >&2; exit 1
  fi
  grep -Fxq 'Offline bundle integrity check failed' "$tmp/refusal.log"
  [[ ! -e "$state" ]]
  cp "$tmp/original-platform" "$package/platform.txt"
  # A validly hashed but incompatible storage mode must fail before image load.
  cp "$package/image-store.txt" "$tmp/original-store"
  cp "$package/SHA256SUMS" "$tmp/original-package-manifest"
  if [[ "$(cat "$package/image-store.txt")" == containerd ]]; then
    echo classic >"$package/image-store.txt"
  else
    echo containerd >"$package/image-store.txt"
  fi
  (cd "$package" && sha256sum image-store.txt >"$tmp/new-store-hash")
  # Keep the exact manifest ordering used by the exporter.
  python3 - "$package/SHA256SUMS" "$tmp/new-store-hash" <<'PY'
from pathlib import Path
import sys
manifest, replacement = map(Path, sys.argv[1:])
manifest.write_text("".join(replacement.read_text() if line.endswith("  image-store.txt\n") else line
                            for line in manifest.read_text().splitlines(keepends=True)))
PY
  other_digest="$(sha256sum "$package/SHA256SUMS" | cut -d ' ' -f1)"
  if RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash "$package/scripts/offline-csharp-local-lab.sh" install "$state" "$other_digest" >"$tmp/refusal.log" 2>&1; then
    echo 'Offline installer accepted incompatible image store' >&2; exit 1
  fi
  grep -Fxq 'Offline bundle image store mismatch; use matching Docker storage mode' "$tmp/refusal.log"
  [[ ! -e "$state" ]]
  cp "$tmp/original-store" "$package/image-store.txt"
  cp "$tmp/original-package-manifest" "$package/SHA256SUMS"
  # Execute the installer from the exported tree, without a checkout or SDK.
  RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash "$package/scripts/offline-csharp-local-lab.sh" install "$state" "$digest"
  echo 'Offline bundle export, integrity refusal and local image import PASS'
  CSHARP_OFFLINE_TEST_ACK=isolated-ci bash scripts/offline-fresh-engine-smoke.sh "$package" "$digest"
else
  RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}"
fi
project="$(cat "$state/project-id")"
[[ "$(stat -c %a "$state")" == 700 && "$(stat -c %a "$state/stack.env")" == 600 ]]
[[ "$(cat "$state/runtime-profile")" == "$runtime" ]]
[[ "$(stat -c %a "$state/manage.sh")" == 700 ]]
(cd "$state" && sha256sum --check --strict --status installation.sha256)
(cd "$state" && bash manage.sh status) >/dev/null
(cd "$state/compose" && sha256sum --check --strict --status SHA256SUMS)
cmp tests/csharp-stack-candidate.compose.yaml "$state/compose/csharp-stack-candidate.compose.yaml"
cmp tests/csharp-stack-local.compose.yaml "$state/compose/csharp-stack-local.compose.yaml"
[[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q radius)")" == "${ids[2]}" ]]
if [[ "$runtime" == slim ]]; then
  stack exec -T radius sh -ec 'if command -v python3 || command -v python; then exit 1; fi; test ! -e /opt/radius/migrate.py'
fi
# Resolved mounts must not reference the source checkout, including DB baseline.
stack config --format json | python3 -c '
import json,sys
from pathlib import Path
state=Path(sys.argv[1])
for service in json.load(sys.stdin)["services"].values():
    assert service.get("pull_policy") == "never"
    assert "build" not in service
    for mount in service.get("volumes", []):
        if mount["type"]=="bind":
            assert Path(mount["source"]).is_relative_to(state)
' "$state"
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
# Reject accidental configuration changes before Docker operations.
cp "$state/compose/csharp-stack-local.compose.yaml" "$tmp/original-compose"
printf '\n# synthetic integrity test\n' >>"$state/compose/csharp-stack-local.compose.yaml"
if (cd "$state" && bash manage.sh stop) >"$tmp/manager-refusal.log" 2>&1; then
  echo 'Manager accepted modified installed Compose file' >&2; exit 1
fi
grep -Fxq 'Local installation integrity check failed' "$tmp/manager-refusal.log"
cp "$tmp/original-compose" "$state/compose/csharp-stack-local.compose.yaml"
[[ "$(stack ps -q db)" == "$db_before" && -n "$(stack ps -q api)" && -n "$(stack ps -q radius)" ]]
# Exercise identity refusal independently of the manifest check, in disposable CI only.
cp "$state/container-identities.txt" "$tmp/original-identities"
cp "$state/installation.sha256" "$tmp/original-manifest"
sed -i "s/^api .*/api $(printf '%064d' 0)/" "$state/container-identities.txt"
(cd "$state" && sha256sum container-identities.txt > "$tmp/new-hash")
sed -i '/  container-identities.txt$/d' "$state/installation.sha256"
cat "$tmp/new-hash" >> "$state/installation.sha256"
if (cd "$state" && bash manage.sh stop) >"$tmp/manager-refusal.log" 2>&1; then
  echo 'Manager accepted substituted container identity' >&2; exit 1
fi
grep -Fxq 'Local service identity mismatch' "$tmp/manager-refusal.log"
cp "$tmp/original-identities" "$state/container-identities.txt"
cp "$tmp/original-manifest" "$state/installation.sha256"
# A competing invocation must fail before changing any running service.
(
  exec 9<"$state"
  flock -n 9
  for action in status start stop; do
    if (cd "$state" && bash manage.sh "$action") >"$tmp/manager-refusal.log" 2>&1; then
      echo 'Manager accepted concurrent lifecycle invocation' >&2; exit 1
    fi
    grep -Fxq 'Local lifecycle operation already in progress' "$tmp/manager-refusal.log"
  done
)
[[ "$(stack ps -q db)" == "$db_before" && -n "$(stack ps -q api)" && -n "$(stack ps -q radius)" ]]
# Stop and start all original services using the standalone installed manager.
(cd "$state" && bash manage.sh stop)
[[ -z "$(stack ps -q db)" && -z "$(stack ps -q api)" && -z "$(stack ps -q radius)" ]]
# A different expected ledger digest must refuse API/RADIUS startup even at the same row count.
cp "$state/ledger.sha256" "$tmp/original-ledger"
printf '%064d\n' 0 >"$state/ledger.sha256"
(cd "$state" && sha256sum ledger.sha256 > "$tmp/new-hash")
sed -i '/  ledger.sha256$/d' "$state/installation.sha256"
cat "$tmp/new-hash" >> "$state/installation.sha256"
if (cd "$state" && bash manage.sh start) >"$tmp/manager-refusal.log" 2>&1; then
  echo 'Manager accepted mismatched migration ledger' >&2; exit 1
fi
grep -Fxq 'Local migration ledger identity mismatch; recovery required' "$tmp/manager-refusal.log"
[[ -z "$(stack ps -q api)" && -z "$(stack ps -q radius)" ]]
cp "$tmp/original-ledger" "$state/ledger.sha256"
cp "$tmp/original-manifest" "$state/installation.sha256"
(cd "$state" && bash manage.sh start)
[[ "$(stack ps -q db)" == "$db_before" ]]
# All four exact container identities must survive the lifecycle.
while read -r svc original; do
  [[ "$(docker inspect --format '{{.Id}}' "$(stack ps -aq "$svc")")" == "$original" ]]
done <"$state/container-identities.txt"
[[ "$(stack exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U radius -d radius -c "SELECT md5(string_agg(row_to_json(m)::text, ',' ORDER BY version)) FROM app_schema_migrations m")" == "$ledger_before" ]]
url="http://$(stack port api 8080)"
ready=0
for attempt in $(seq 1 30); do
  if curl --silent --fail "$url/api/health/ready" >/dev/null &&
     [[ "$(docker inspect --format '{{.State.Health.Status}}' "$(stack ps -q radius)")" == healthy ]]; then
    ready=1; break
  fi
  sleep 2
done
[[ "$ready" == 1 ]]
RADIUS_UI_URL="$url" bash scripts/ui-smoke.sh
# Compare the actual fresh compatible and slim installations after restart.
python3 tests/local_stack_performance.py "$state"
echo 'Actual local C# installer, overwrite refusal and persistent restart PASS'
echo 'Installed manager rejects changed configuration and restarts original containers PASS'
if [[ "$runtime" == slim ]]; then
  [[ "$(docker inspect --format '{{.Image}}' "$(stack ps -q radius)")" == "$RADIUS_SLIM_IMAGE_ID" ]]
  echo 'Python-free image accepted by actual local installer and independent persisted Compose restart PASS'
fi
