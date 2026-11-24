#!/usr/bin/env bash
# Scan actual isolated CI images by immutable local ID. No production access.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_SECURITY_SCAN_ACK:-}" == isolated-ci ]] || {
  echo 'Security scan requires isolated CI acknowledgement' >&2; exit 1;
}
[[ "$(uname -m)" == x86_64 ]] || { echo 'Unsupported scanner architecture' >&2; exit 1; }
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
reports="$RUNNER_TEMP/radius-security-reports"
mkdir -p "$reports"
version=0.76.2
archive="trivy_${version}_Linux-64bit.tar.gz"
curl --fail --silent --show-error --location --retry 2 \
  "https://github.com/aquasecurity/trivy/releases/download/v$version/$archive" \
  -o "$tmp/$archive"
printf '%s  %s\n' 'bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf' "$tmp/$archive" | sha256sum -c -
tar -xzf "$tmp/$archive" -C "$tmp" trivy
scanner="$tmp/trivy"
"$scanner" --version
# Inventory dependency lockfiles only, not the workspace containing lab secrets.
for path in src/RadiusManager.Api/packages.lock.json tests/RadiusManager.Tests/packages.lock.json \
            src/RadiusManager.Api/frontend/package-lock.json tests/browser/package-lock.json; do
  mkdir -p "$tmp/locks/$(dirname "$path")"
  cp "$path" "$tmp/locks/$path"
done
"$scanner" fs --format cyclonedx --output "$reports/source.cdx.json" "$tmp/locks"
failed=0
for service in api radius db; do
  container=$(docker compose ps -q "$service")
  [[ -n "$container" && "$container" != *$'\n'* ]] || { echo "Missing unique container: $service" >&2; exit 1; }
  image=$(docker inspect --format '{{.Image}}' "$container")
  [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "Invalid image ID: $service" >&2; exit 1; }
  printf '%s %s\n' "$service" "$image" >> "$reports/image-identities.txt"
  "$scanner" image --image-src docker --format cyclonedx \
    --output "$reports/$service.cdx.json" "$image"
  # Do not suppress unfixed vulnerabilities, skip DB refresh, or waive failures.
  if "$scanner" image --image-src docker --scanners vuln --severity HIGH,CRITICAL \
      --exit-code 1 --exit-on-eol 1 --format json \
      --output "$reports/$service.vulnerabilities.json" "$image"; then
    echo "Image vulnerability gate passed: $service"
  else
    echo "Image vulnerability gate failed: $service" >&2
    failed=1
  fi
done
# Require actual SBOM component inventories and vulnerability reports.
python3 - "$reports" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
for name in ("source", "api", "radius", "db"):
    data = json.loads((root / (name + ".cdx.json")).read_text())
    if data.get("bomFormat") != "CycloneDX" or not data.get("components"):
        raise SystemExit("Missing component inventory: " + name)
    print("SBOM", name, len(data["components"]), "components")
for name in ("api", "radius", "db"):
    data = json.loads((root / (name + ".vulnerabilities.json")).read_text())
    if not data.get("Results"):
        raise SystemExit("Missing image scan results: " + name)
    for result in data["Results"]:
        for vuln in result.get("Vulnerabilities") or []:
            print(name, vuln.get("VulnerabilityID"), vuln.get("PkgName"),
                  vuln.get("InstalledVersion"), vuln.get("Severity"))
PY
exit "$failed"
