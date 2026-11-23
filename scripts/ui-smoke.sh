#!/usr/bin/env bash
set -euo pipefail
URL="${RADIUS_UI_URL:-http://127.0.0.1:8080}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
curl --fail --silent --show-error "$URL/" -o "$OUT/index.html"
curl --fail --silent --show-error "$URL/styles.css" -o "$OUT/styles.css"
curl --fail --silent --show-error "$URL/app.mjs" -o "$OUT/app.mjs"
curl --fail --silent --show-error "$URL/dashboard-utils.mjs" -o "$OUT/dashboard-utils.mjs"
grep -q 'id="view-overview"' "$OUT/index.html"
grep -q 'id="view-accounting"' "$OUT/index.html"
grep -q 'id="labForm"' "$OUT/index.html"
grep -q 'filterAccounts' "$OUT/dashboard-utils.mjs"
grep -q '/api/lab-accounts' "$OUT/app.mjs"
# UI assets are public, but the real backend must still enforce authentication.
status="$(curl --silent --output "$OUT/unauthorized" --write-out '%{http_code}' "$URL/api/lab-accounts")"
[[ "$status" == 401 ]] || { echo "Lab accounts API must require authentication, got $status" >&2; exit 1; }
echo 'Dashboard static assets and API authorization checks passed.'
