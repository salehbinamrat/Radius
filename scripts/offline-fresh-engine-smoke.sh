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
# unshare --net changes the network namespace, but an inherited sysfs mount
# still exposes the host network devices. Preserve the cgroup mount, then
# mount sysfs from inside this network namespace (private mount propagation).
mkdir -- "$work/cgroup-view" "$work/containerd-run" "$work/docker-run"
mount --bind /sys/fs/cgroup "$work/cgroup-view"
mount -t sysfs -o nosuid,nodev,noexec sysfs /sys
mount --bind "$work/cgroup-view" /sys/fs/cgroup
[[ "$(ls -A /sys/class/net)" == lo ]]
# containerd's auxiliary ttrpc/shim sockets and Docker's network namespace
# handles also use fixed /run paths, independently of --root/--state.
[[ -d /run/containerd && -d /run/docker ]]
mount --bind "$work/containerd-run" /run/containerd
mount --bind "$work/docker-run" /run/docker
[[ -z "$(ls -A /run/containerd)" && -z "$(ls -A /run/docker)" ]]
echo 'Private sysfs, containerd runtime paths and Docker runtime paths verified'
no_external_route() {
  [[ -z "$(ip -4 route show default)" && -z "$(ip -6 route show default)" ]]
}
no_external_route
# Match the source image store: Docker 29's OCI manifest ID differs from the
# classic config ID. Never share the host containerd socket or its state.
store="$(cat "$package/image-store.txt")"
case "$store" in
  containerd) printf '%s\n' '{"features":{"containerd-snapshotter":true}}' >"$work/daemon.json"; driver=overlayfs ;;
  classic) printf '%s\n' '{"features":{"containerd-snapshotter":false}}' >"$work/daemon.json"; driver=vfs ;;
  *) exit 2 ;;
esac
daemon=
runtime=
finish() {
  local result=$?
  if (( result != 0 )); then
    # Preserve the original failed service's diagnostics before the disposable
    # engine is stopped. Never query the host socket or dump environment/SQL.
    if [[ -S "$work/docker.sock" ]] &&
       [[ "$(docker --host "unix://$work/docker.sock" info --format '{{.DockerRootDir}}' 2>/dev/null)" == "$work/data" ]]; then
      diagnostic_docker() { docker --host "unix://$work/docker.sock" "$@"; }
      echo 'Offline isolated engine service diagnostics:' >&2
      diagnostic_docker ps -a --format '{{.Names}} {{.Status}}' >&2 || true
      while read -r cid; do
        [[ "$cid" =~ ^[a-f0-9]{64}$ ]] || continue
        diagnostic_docker inspect --format '{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' "$cid" >&2 || true
        service="$(diagnostic_docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$cid" 2>/dev/null)" || continue
        case "$service" in
          db|schema-init) diagnostic_docker logs --tail 100 "$cid" >&2 || true ;;
        esac
      done < <(diagnostic_docker ps -aq --no-trunc)
    fi
    for log in "$work/daemon.log" "$work/containerd.log"; do
      if [[ -f "$log" ]]; then tail -n 80 "$log" >&2 || true; fi
    done
  fi
  if [[ -n "$daemon" ]]; then kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; fi
  if [[ -n "$runtime" ]]; then kill "$runtime" 2>/dev/null || true; wait "$runtime" 2>/dev/null || true; fi
  exit "$result"
}
trap finish EXIT
containerd config default >"$work/containerd.toml"
containerd --config "$work/containerd.toml" --root "$work/containerd-data" \
  --state "$work/containerd-state" --address "$work/containerd.sock" >"$work/containerd.log" 2>&1 &
runtime=$!
runtime_ready=0
for attempt in $(seq 1 30); do
  if ctr --address "$work/containerd.sock" version >/dev/null 2>&1; then runtime_ready=1; break; fi
  kill -0 "$runtime" || exit 1
  sleep 1
done
[[ "$runtime_ready" == 1 ]]
[[ -z "$(ctr --address "$work/containerd.sock" namespaces list -q)" ]]
dockerd --config-file "$work/daemon.json" --host "unix://$work/docker.sock" \
  --containerd "$work/containerd.sock" --data-root "$work/data" --exec-root "$work/exec" \
  --pidfile "$work/docker.pid" --storage-driver "$driver" \
  --exec-opt native.cgroupdriver=cgroupfs --cgroup-parent "/${work##*/}" >"$work/daemon.log" 2>&1 &
daemon=$!
ready=0
for attempt in $(seq 1 60); do
  if docker --host "unix://$work/docker.sock" info >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$daemon" || exit 1
  sleep 1
done
[[ "$ready" == 1 ]]
# Verify that the bridge created by the private daemon is visible through
# both netlink and the matching sysfs mount before starting any application.
ip link show docker0 >/dev/null
[[ -d /sys/class/net/docker0/bridge ]]
# Never continue if mounting or identity validation fails.
mount --bind "$work/docker.sock" /var/run/docker.sock
docker_local() { docker --host unix:///var/run/docker.sock "$@"; }
isolated_id="$(docker_local info --format '{{.ID}}')"
[[ -n "$isolated_id" && "$isolated_id" != "$host_id" ]]
[[ "$(docker_local info --format '{{.DockerRootDir}}')" == "$work/data" ]]
# Host systemd cannot address PIDs from the private PID namespace.
[[ "$(docker_local info --format '{{.CgroupDriver}}')" == cgroupfs ]]
echo 'Independent engine uses cgroupfs instead of host systemd'
driver_status="$(docker_local info --format '{{json .DriverStatus}}')"
if [[ "$store" == containerd ]]; then
  [[ "$driver_status" == *io.containerd.snapshotter.v1* ]]
else
  [[ "$driver_status" != *io.containerd.snapshotter.v1* ]]
fi
echo "Independent containerd and matching image store: $store"
[[ -z "$(docker_local image ls -aq)" && -z "$(docker_local ps -aq)" && -z "$(docker_local volume ls -q)" ]]
no_external_route
echo 'Fresh isolated Docker engine: no images, containers, volumes or external default route'
state="$work/install"
echo 'Starting verified offline package installation on isolated engine'
RADIUS_LOCAL_INSTALL_ACK=local-lab-only bash "$package/scripts/offline-csharp-local-lab.sh" install "$state" "$digest"
# Exactly the three transported images; the installer creates only its own tags.
# Compare exact expected IDs after loading; fail closed on missing or extra IDs.
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
