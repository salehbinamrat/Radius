#!/usr/bin/env bash
# Validate each source file independently; never execute it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shopt -s globstar nullglob
shell_count=0
for directory in scripts radius tests; do
  files=("$directory"/**/*.sh)
  ((${#files[@]} > 0)) || { echo "No shell sources in $directory" >&2; exit 1; }
  for file in "${files[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] || { echo "Invalid shell source: $file" >&2; exit 1; }
    bash -n -- "$file"
    ((shell_count += 1))
  done
done
modules=(src/RadiusManager.Api/wwwroot/**/*.mjs)
((${#modules[@]} > 0)) || { echo 'No frontend modules were checked' >&2; exit 1; }
for file in "${modules[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "Invalid frontend source: $file" >&2; exit 1; }
  node --check "$file"
done
printf 'Checked %s shell sources and %s frontend ES modules.\n' "$shell_count" "${#modules[@]}"
