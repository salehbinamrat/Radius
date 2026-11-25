#!/usr/bin/env bash
# Disposable hosted CI only: fresh Docker storage and no external network routes.
set -euo pipefail
set +x
[[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true &&
   "${CSHARP_OFFLINE_TEST_ACK:-}" == isolated-ci ]] || exit 2
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# == 2 && "$1" == /* && "$2" =~ ^[a-f0-9]{64}$ ]] || exit 2
package="$1"; digest="$2"
# The bundle is prepared once by the existing slim installer test.
[[ -f "$package/SHA256SUMS" && -f "$package/images.tar.gz" ]]
host_id="$(docker --host unix:///var/run/docker.sock info --format '{{.ID}}')"
host_mount="$(readlink /proc/self/ns/mnt)"
host_net="$(readlink /proc/self/ns/net)"
work="$(mktemp -d /tmp/radius-offline-ci.XXXXXXXX)"
cleanup() {
  local result=$?
  if [[ "$work" =~ ^/tmp/radius-offline-ci\.[a-zA-Z0-9]{8}$ ]]; then
    sudo rm -rf -- "$work" || result=1
  else
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
# No alternate socket support is added to the real installer.
# Replace the socket only within the private mount namespace.
sudo env -i PATH="$PATH" HOME=/root CI=true \
  unshare --mount --net --pid --fork --kill-child --mount-proc --propagation private \
  bash -s -- "$work" "$package" "$digest" "$host_id" "$host_mount" "$host_net" "$root/scripts/ui-smoke.sh" <<'ISOLATED'
set -euo pipefail
set +x
work="$1"; package="$2"; digest="$3"; host_id="$4"; host_mount="$5"; host_net="$6"; ui="$7"
[[ "$(readlink /proc/self/ns/mnt)" != "$host_mount" && "$(readlink /proc/self/ns/net)" != "$host_net" ]]
[[ "$(ip -o link show | wc -l)" == 1 ]]
ip link set lo up
no_external_route() {
  [[ -z "$(ip -4 route show default)" && -z "$(ip -6 route show default)" ]]
}
no_external_route
printf '%s\n' '{"features":{"containerd-snapshotter":false}}' >"$work/daemon.json"
dockerd --config-file "$work/daemon.json" --host "unix://$work/docker.sock" \
  --data-root "$work/data" --exec-root "$work/exec" --pidfile "$work/docker.pid" \
  --storage-driver vfs >"$work/daemon.log" 2>&1 &
daemon=$!
finish() {
  local result=$?
  if (( result != 0 )); then tail -n 80 "$work/daemon.log" >&2 || true; fi
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  exit "$result"
}
trap finish EXIT
ready=0
for attempt in $(seq 1 60); do
  if docker --host "unix://$work/docker.sock" info >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$daemon" || exit 1
  sleep 1
done
[[ "$ready" == 1 ]]
# Never continue if mounting or identity validation fails.
mount --bind "$work/docker.sock" /var/run/docker.sock
docker_local() { docker --host unix:///var/run/docker.sock "$@"; }
isolated_id="$(docker_local info --format '{{.ID}}')"
[[ -n "$isolated_id" && "$isolated_id" != "$host_id" ]]
[[ "$(docker_local info --format '{{.DockerRootDir}}')" == "$work/data" ]]
[[ -z "$(docker_local image ls -aq)" && -z "$(docker_local ps -aq)" && -z "$(docker_local volume ls -q)" ]]
no_external_route
echo 'Fresh isolated Docker engine: no images, containers, volumes or external default route'
state="$work/install"
RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash "$package/scripts/offline-csharp-local-lab.sh" install "$state" "$digest"
# Exactly the three transported images; the installer creates only its own tags.
diff -u <(sort "$package/image-ids.txt") <(docker_local image ls -aq --no-trunc | sort -u)
[[ "$(docker_local ps -aq | wc -l)" == 4 ]]
[[ "$(docker_local ps -q | wc -l)" == 3 ]]
url="$(cat "$state/api-url")"
RADIUS_UI_URL="$url" bash "$ui"
bash "$state/manage.sh" status
bash "$state/manage.sh" stop
[[ -z "$(docker_local ps -q)" ]]
bash "$state/manage.sh" start
[[ "$(docker_local ps -q | wc -l)" == 3 ]]
RADIUS_UI_URL="$(cat "$state/api-url")" bash "$ui"
no_external_route
echo 'Offline fresh-engine installation and persistent restart PASS'
ISOLATED
[[ "$(docker --host unix:///var/run/docker.sock info --format '{{.ID}}')" == "$host_id" ]]
