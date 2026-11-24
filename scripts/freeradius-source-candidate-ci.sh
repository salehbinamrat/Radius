#!/usr/bin/env bash
# Isolated source remediation experiment, not a supported release or deployment.
set -euo pipefail
[[ "${CI:-}" == true && "${LAB_SECURITY_SCAN_ACK:-}" == isolated-ci ]] || exit 1
[[ $# == 2 && -x "$1" && -d "$2" ]] || exit 1
scanner=$(realpath "$1")
reports=$(realpath "$2")
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

revision=00abf778c6c0af0320879c2b1ade9cf252a42506
sim_fix=8e8a991c040cbb30f21f928f2b406c702e171b2e
fast_fix=064567a08f3b9d9b4863fab6060fafe296ac7de9
base=alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
source=https://github.com/FreeRADIUS/freeradius-server.git
git init -q "$tmp/source"
git -C "$tmp/source" remote add origin "$source"
# Full ancestry is required to verify the fixes; do not use a shallow clone.
git -C "$tmp/source" fetch --no-tags --filter=blob:none origin "$revision"
git -C "$tmp/source" checkout --detach "$revision"
[[ "$(git -C "$tmp/source" rev-parse HEAD)" == "$revision" ]] || exit 1
for fix in "$sim_fix" "$fast_fix"; do
  git -C "$tmp/source" merge-base --is-ancestor "$fix" "$revision"
done
recipe="$tmp/source/scripts/docker/dists/alpine/Dockerfile"
[[ -f "$recipe" ]] || exit 1
{
  printf 'source=%s\nrevision=%s\nCVE-2026-127029-fix=%s\nCVE-2026-127030-fix=%s\nbase=%s\n' \
    "$source" "$revision" "$sim_fix" "$fast_fix" "$base"
  sha256sum "$recipe"
  echo 'Unreleased upstream revision; ancestry evidence, not a release attestation.'
} > "$reports/radius-source-candidate.provenance.txt"

# Build upstream's own pinned recipe; no workspace or application secrets
# enter this context. Use the distribution's signed package repositories.
docker build --pull --no-cache --iidfile "$tmp/upstream-image-id" \
  --build-arg "from=$base" -f "$recipe" "$tmp/source"
upstream_id=$(cat "$tmp/upstream-image-id")
[[ "$upstream_id" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
upstream_tag="radius-upstream-probe:${upstream_id#sha256:}"
docker tag "$upstream_id" "$upstream_tag"
mkdir "$tmp/runtime"
cat > "$tmp/runtime/Dockerfile" <<'DOCKER'
ARG UPSTREAM_IMAGE
FROM ${UPSTREAM_IMAGE}
# Required PostgreSQL driver and existing migration/runtime tooling.
RUN apk add --no-cache libpq bash python3 py3-psycopg2 postgresql16-client ca-certificates
DOCKER
docker build --no-cache --iidfile "$tmp/candidate-image-id" \
  --build-arg "UPSTREAM_IMAGE=$upstream_tag" "$tmp/runtime"
image=$(cat "$tmp/candidate-image-id")
[[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
printf 'image=%s\n' "$image" >> "$reports/radius-source-candidate.provenance.txt"

# A source-built server may not be recognized by an OS package scanner.
# Retain the real source identity and dependency inventory separately.
# Never interpret a clean OS scan as proof of complete FreeRADIUS safety.
"$scanner" image --image-src docker --format cyclonedx \
  --output "$reports/radius-source-candidate.cdx.json" "$image"
failed=0
if ! "$scanner" image --image-src docker --scanners vuln --severity HIGH,CRITICAL \
    --exit-code 1 --exit-on-eol 1 --format json \
    --output "$reports/radius-source-candidate.vulnerabilities.json" "$image"; then
  failed=1
fi
python3 - "$reports" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
sbom = json.loads((root / "radius-source-candidate.cdx.json").read_text())
if sbom.get("bomFormat") != "CycloneDX" or not sbom.get("components"):
    raise SystemExit("Missing candidate component inventory")
report = json.loads((root / "radius-source-candidate.vulnerabilities.json").read_text())
if not report.get("Results"):
    raise SystemExit("Missing candidate vulnerability results")
for result in report["Results"]:
    for vuln in result.get("Vulnerabilities") or []:
        print("radius-source-candidate", vuln.get("VulnerabilityID"), vuln.get("PkgName"),
              vuln.get("InstalledVersion"), vuln.get("Severity"),
              "fixed-version:", vuln.get("FixedVersion") or "not-reported")
PY
# Offline smoke only. No exposed port, mounted data, or real NAS.
# Check the executable, SQL schema, PostgreSQL driver and migration imports.
if ! docker run --rm --network none --entrypoint /bin/sh "$image" -ec '
  /opt/sbin/radiusd -v
  test -x /opt/bin/radclient
  test -s /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql
  driver=$(find /opt/lib -name rlm_sql_postgresql.so -print -quit)
  test -n "$driver"
  ldd "$driver" > /tmp/driver-dependencies
  cat /tmp/driver-dependencies
  if grep -Eqi "not found|Error loading|Error relocating" /tmp/driver-dependencies; then exit 1; fi
  psql --version
  python3 -c "import psycopg2"
  apk info -v
' > "$reports/radius-source-candidate.runtime.txt" 2>&1; then
  cat "$reports/radius-source-candidate.runtime.txt"
  failed=1
fi
cat "$reports/radius-source-candidate.runtime.txt"
if [[ "$failed" != 0 ]]; then
  echo 'FreeRADIUS source candidate probe FAILED' >&2
  exit 1
fi
echo 'FreeRADIUS source candidate probe PASS (NOT runtime approval)'
