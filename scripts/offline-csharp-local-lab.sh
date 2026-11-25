#!/usr/bin/env bash
# Transfer only trusted, prebuilt laboratory images and the exact installer inputs.
set -euo pipefail
set +x
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$PWD"
[[ "${RADIUS_LOCAL_INSTALL_ACK:-}" == local-lab-only ]] || {
  echo 'Offline bundle requires local-lab-only authorization' >&2; exit 2;
}
files=(scripts/offline-csharp-local-lab.sh scripts/install-csharp-local-lab.sh
       scripts/manage-csharp-local-lab.sh scripts/export-csharp-init-bundle.sh
       tests/csharp-stack-candidate.compose.yaml tests/csharp-stack-local.compose.yaml
       radius/Dockerfile LICENSES.md
       database/001_app.sql database/002_lab_accounts.sql database/003_accounting.sql
       database/004_nas_drafts.sql database/005_admin_identity.sql database/006_reseller_ownership.sql
       database/007_ownership_transfers.sql database/008_audit_append_only.sql
       database/009_accounting_read_indexes.sql database/010_accounting_quality.sql)
local_docker() { env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock "$@"; }
new_directory() {
  [[ "$1" =~ ^/[a-zA-Z0-9_./-]+$ && "$1" == "$(realpath -m -- "$1")" &&
     ! -e "$1" && ! -L "$1" && -d "$(dirname "$1")" ]]
}
verify_ids() {
  [[ $# == 3 && "$1" != "$2" && "$1" != "$3" && "$2" != "$3" ]] || return 1
  for id in "$@"; do [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1; done
}
local_platform() {
  case "$(local_docker info --format '{{.OSType}}/{{.Architecture}}')" in
    linux/x86_64|linux/amd64) echo linux/amd64 ;;
    linux/aarch64|linux/arm64) echo linux/arm64 ;;
    *) return 1 ;;
  esac
}
check_images() {
  local id
  for id in "$@"; do
    [[ "$(local_docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$id")" == "$id $platform" ]] || return 1
  done
}
manifest() { sha256sum -- "${files[@]}" image-ids.txt platform.txt images.tar.gz; }
case "${1:-}" in
  export)
    [[ $# == 5 ]] || exit 2
    destination="$2"; shift 2
    new_directory "$destination" && verify_ids "$@" || { echo 'Invalid bundle destination or image IDs' >&2; exit 2; }
    platform="$(local_platform)"
    check_images "$@"
    for file in "${files[@]}"; do [[ -f "$file" && ! -L "$file" ]] || exit 2; done
    umask 077
    mkdir -- "$destination"
    for file in "${files[@]}"; do
      mkdir -p -- "$destination/$(dirname "$file")"
      install -m 644 -- "$file" "$destination/$file"
    done
    printf '%s\n' "$@" >"$destination/image-ids.txt"
    printf '%s\n' "$platform" >"$destination/platform.txt"
    # Save by immutable ID rather than mutable registry tags.
    local_docker image save "$@" | gzip -1 >"$destination/images.tar.gz"
    (cd "$destination" && manifest >SHA256SUMS.tmp && mv -- SHA256SUMS.tmp SHA256SUMS)
    (cd "$destination" && sha256sum SHA256SUMS)
    ;;
  install)
    [[ $# == 3 && "$3" =~ ^[a-f0-9]{64}$ ]] || exit 2
    state="$2"; trusted="$3"
    new_directory "$state" || { echo 'Invalid or existing installation destination' >&2; exit 2; }
    for file in "${files[@]}" image-ids.txt platform.txt images.tar.gz SHA256SUMS; do
      [[ -f "$file" && ! -L "$file" && "$(realpath -- "$file")" == "$root/$file" ]] || exit 2
    done
    [[ "$(sha256sum SHA256SUMS | cut -d ' ' -f1)" == "$trusted" ]] &&
      manifest | cmp -s -- SHA256SUMS - || { echo 'Offline bundle integrity check failed' >&2; exit 2; }
    mapfile -t ids <image-ids.txt
    verify_ids "${ids[@]}" || exit 2
    platform="$(local_platform)"
    [[ "$(cat platform.txt)" == "$platform" ]] || { echo 'Offline bundle platform mismatch' >&2; exit 2; }
    local_docker compose version >/dev/null
    # Import only the trusted image archive; never pull or build.
    local_docker image load --input images.tar.gz --quiet
    check_images "${ids[@]}"
    exec env RADIUS_LOCAL_RUNTIME=slim bash scripts/install-csharp-local-lab.sh "$state" "${ids[@]}"
    ;;
  *)
    echo 'Usage: offline-csharp-local-lab.sh export /new-bundle DB_ID API_ID RADIUS_ID | install /new-state TRUSTED_MANIFEST_SHA256' >&2
    exit 2 ;;
esac
