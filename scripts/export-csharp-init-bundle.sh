#!/usr/bin/env bash
# Export only public SQL from the pinned local image and checked-out migration files.
# No network access, database connection, Docker volume or credential is needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $# == 2 && "$1" =~ ^sha256:[a-f0-9]{64}$ && "$2" == /* ]] || {
  echo 'Usage: export-csharp-init-bundle.sh sha256:IMAGE_ID /absolute/new-directory' >&2
  exit 2
}
image="$1"
destination="$2"
[[ ! -e "$destination" && ! -L "$destination" ]] || {
  echo 'Migration bundle destination already exists; refusing overwrite' >&2; exit 2;
}
[[ "$(docker image inspect --format '{{.Id}}' "$image")" == "$image" ]] || exit 1
read_image() {
  docker run --rm --pull never --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --entrypoint cat "$image" "$1"
}
revision=$(read_image /opt/share/radius-build/revision)
[[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo 'Invalid source revision' >&2; exit 1; }
grep -Fxq "    revision=$revision; \\" radius/Dockerfile || {
  echo 'FreeRADIUS image revision differs from pinned recipe' >&2; exit 1;
}
# No globbing over unrelated SQL or secrets; enforce the exact ordered ten versions.
files=(database/[0-9][0-9][0-9]_*.sql)
[[ ${#files[@]} == 10 ]]
for i in "${!files[@]}"; do
  printf -v prefix '%03d_' "$((i+1))"
  [[ "${files[$i]##*/}" == "$prefix"* && -f "${files[$i]}" && ! -L "${files[$i]}" ]]
done
umask 022
# mkdir is exclusive; never modify a pre-existing destination.
mkdir -- "$destination"
mkdir -- "$destination/migrations"
read_image /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql >"$destination/official.sql"
test -s "$destination/official.sql"
for file in "${files[@]}"; do
  cp -- "$file" "$destination/migrations/${file##*/}"
done
printf '%s\n' "$image" >"$destination/image-id.txt"
printf '%s\n' "$revision" >"$destination/source-revision.txt"
(
  cd "$destination"
  # Publish the integrity manifest only after all files exist.
  sha256sum official.sql migrations/*.sql image-id.txt source-revision.txt > SHA256SUMS.tmp
  sha256sum --check --strict --status SHA256SUMS.tmp
  mv -- SHA256SUMS.tmp SHA256SUMS
)
echo 'Migration input bundle exported: 10 immutable migrations, official schema and source identity'
