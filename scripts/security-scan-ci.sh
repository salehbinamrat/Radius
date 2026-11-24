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
# Compare an official same-major PostgreSQL candidate without starting it,
# mounting any volume, or replacing the deployed image. It cannot waive the
# current runtime gate. Both results must remain visible.
candidate='postgres:16.16-trixie@sha256:820b1558a744efeda508506fd85bff573cec8b6941ff4790ef4884a526dd6e86'
docker pull "$candidate"
candidate_id=$(docker image inspect --format '{{.Id}}' "$candidate")
[[ "$candidate_id" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
printf '%s %s\n' candidate-db "$candidate_id" >> "$reports/image-identities.txt"
"$scanner" image --image-src docker --format cyclonedx --output "$reports/candidate-db.cdx.json" "$candidate_id"
if "$scanner" image --image-src docker --scanners vuln --severity HIGH,CRITICAL \
    --exit-code 1 --exit-on-eol 1 --format json \
    --output "$reports/candidate-db.vulnerabilities.json" "$candidate_id"; then
  echo 'Candidate image vulnerability gate passed'
else
  echo 'Candidate image vulnerability gate failed' >&2
  failed=1
fi
# Build the Alpine candidate with the vendor-published fix. No run or
# volumes; a different libc requires an isolated logical restore before use.
docker build --pull --no-cache --iidfile "$tmp/alpine-image-id" \
  -f tests/postgres-alpine-remediation.Dockerfile tests
candidate_id=$(cat "$tmp/alpine-image-id")
# Scan the exact built image, not the original vulnerable base.
candidate_id=$(docker image inspect --format '{{.Id}}' "$candidate_id")
[[ "$candidate_id" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
printf '%s %s\n' candidate-alpine "$candidate_id" >> "$reports/image-identities.txt"
# Confirm the final image does not distribute the vulnerable old layer.
docker image inspect "$candidate_id" > "$tmp/alpine-inspect.json"
python3 - "$tmp/alpine-inspect.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    image = json.load(f)[0]
layers = image["RootFS"]["Layers"]
forbidden_layer = "sha256:313cac38511bcff0f059dfb294ab2fb1f9d2b23488e152ec139ba8d7b3b0f47f"
if not layers or forbidden_layer in layers:
    raise SystemExit("vulnerable image layer retained or missing filesystem")
if len(layers) > 2:
    raise SystemExit("Unexpected inherited image layers")
config = image["Config"]
expected = {"Entrypoint": ["docker-entrypoint.sh"], "Cmd": ["postgres"], "StopSignal": "SIGINT"}
for field, value in expected.items():
    if config.get(field) != value:
        raise SystemExit("PostgreSQL image metadata mismatch: " + field)
if "/var/lib/postgresql/data" not in (config.get("Volumes") or {}):
    raise SystemExit("Missing PostgreSQL data volume metadata")
if "5432/tcp" not in (config.get("ExposedPorts") or {}):
    raise SystemExit("Missing PostgreSQL port metadata")
env = dict(item.split("=", 1) for item in config["Env"])
for name, value in {"PG_MAJOR": "16", "PG_VERSION": "16.16",
                    "PGDATA": "/var/lib/postgresql/data"}.items():
    if env.get(name) != value:
        raise SystemExit("PostgreSQL environment mismatch: " + name)
print("Clean PostgreSQL candidate image layers and runtime metadata PASS")
PY
"$scanner" image --image-src docker --format cyclonedx --output "$reports/candidate-alpine.cdx.json" "$candidate_id"
if "$scanner" image --image-src docker --scanners vuln --severity HIGH,CRITICAL \
    --exit-code 1 --exit-on-eol 1 --format json \
    --output "$reports/candidate-alpine.vulnerabilities.json" "$candidate_id"; then
  echo 'Alpine candidate vulnerability gate passed'
else
  echo 'Alpine candidate vulnerability gate failed' >&2
  failed=1
fi
# Require actual SBOM component inventories and vulnerability reports.
python3 - "$reports" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
for name in ("source", "api", "radius", "db", "candidate-db", "candidate-alpine"):
    data = json.loads((root / (name + ".cdx.json")).read_text())
    if data.get("bomFormat") != "CycloneDX" or not data.get("components"):
        raise SystemExit("Missing component inventory: " + name)
    print("SBOM", name, len(data["components"]), "components")
for name in ("api", "radius", "db", "candidate-db", "candidate-alpine"):
    data = json.loads((root / (name + ".vulnerabilities.json")).read_text())
    if not data.get("Results"):
        raise SystemExit("Missing image scan results: " + name)
    for result in data["Results"]:
        for vuln in result.get("Vulnerabilities") or []:
            print(name, vuln.get("VulnerabilityID"), vuln.get("PkgName"),
                  vuln.get("InstalledVersion"), vuln.get("Severity"),
                  "fixed-version:", vuln.get("FixedVersion") or "not-reported",
                  "status:", vuln.get("Status") or "unknown",
                  "target:", result.get("Target") or "unknown")
PY
exit "$failed"
