#!/usr/bin/env bash
# Small read-only latency baseline for an isolated loopback lab; NOT a load SLA.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ "${RADIUS_PERF_TEST_ACK:-}" != "isolated-ci" ]]; then
  echo "RADIUS_PERF_TEST_ACK=isolated-ci is required; no remote target supported." >&2
  exit 2
fi
[[ -f .env ]] || { echo "Missing .env; run scripts/setup.sh" >&2; exit 2; }
set -a; source .env; set +a
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API="http://127.0.0.1:8080/api"
umask 077
netrc=$(mktemp)
samples=$(mktemp)
trap 'rm -f "$netrc" "$samples"' EXIT
# A private, short-lived netrc file avoids secrets on curl command lines or in logs.
printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$netrc"

# Baseline also checks unauthenticated access and secure static response headers.
unauth=$(curl --silent --show-error -o /dev/null -w '%{http_code}' "$API/plans")
[[ "$unauth" == 401 ]] || { echo "Protected API must return HTTP 401, got $unauth" >&2; exit 1; }
headers=$(curl --fail --silent --show-error --head http://127.0.0.1:8080/)
for header in '^content-security-policy: default-src' '^x-frame-options: DENY' \
              '^x-content-type-options: nosniff' '^cache-control: no-store'; do
  if ! printf '%s\n' "$headers" | grep -qi "$header"; then
    echo "Expected security response header is missing: $header" >&2
    exit 1
  fi
done

for endpoint in summary plans lab-accounts; do
  for i in {1..8}; do
    result=$(curl --netrc --netrc-file "$netrc" --fail --silent --show-error \
      --max-time 5 --output /dev/null --write-out '%{http_code} %{time_total}' "$API/$endpoint")
    read -r status seconds <<< "$result"
    [[ "$status" == 200 ]] || { echo "Read baseline failed on $endpoint: HTTP $status" >&2; exit 1; }
    printf '%s %s\n' "$endpoint" "$seconds" >> "$samples"
  done
done

python3 - "$samples" <<'PY'
from collections import defaultdict
from math import ceil
from pathlib import Path
import sys

metrics = defaultdict(list)
for row in Path(sys.argv[1]).read_text().splitlines():
    name, latency = row.split()
    value = float(latency)
    if not 0 <= value <= 5:
        raise SystemExit("Invalid latency returned by curl")
    metrics[name].append(value)
for name in ("summary", "plans", "lab-accounts"):
    values = sorted(metrics[name])
    if len(values) != 8:
        raise SystemExit("Incomplete laboratory read samples")
    p50 = values[(len(values) - 1) // 2]
    p95 = values[ceil(0.95 * len(values)) - 1]
    print(f"LAB READ BASELINE {name}: count=8 p50={p50:.4f}s p95={p95:.4f}s")
print("No writes, no production requests, and no final performance SLA was claimed.")
PY
