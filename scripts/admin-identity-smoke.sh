#!/usr/bin/env bash
# Identity endpoints are DISABLED in the existing HTTP-only lab; never leak auth cookies or user data.
set -euo pipefail
cd "$(dirname "$0")/.."
API="http://127.0.0.1:8080"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
check() {
  local expected="$1"; shift
  local status
  status=$(curl -sS -o "$out" -w '%{http_code}' "$@")
  if [[ "$status" != "$expected" ]]; then
    echo "Expected HTTP $expected, got $status while testing admin security" >&2
    exit 1
  fi
}
# Session-only authentication cannot be used over this non-HTTPS lab.
check 200 "$API/api/admin/auth/mode"
grep -q '"basic"' "$out"
check 404 "$API/api/admin/auth/csrf"
check 404 -H 'Content-Type: application/json' \
  -d '{"username":"nonexistent","password":"not-a-secret"}' "$API/api/admin/auth/login"
check 404 -H 'Content-Type: application/json' \
  -d '{}' "$API/api/admin/auth/logout"
# The original Basic-protected API is still protected, not bypassed by the new routes.
check 401 "$API/api/plans"
# A cross-origin browser cannot induce an administrative login.
check 403 -H 'Origin: https://evil.example' -H 'Content-Type: application/json' \
  -d '{"username":"test","password":"wrong"}' "$API/api/admin/auth/login"
echo 'Admin HTTPS/cookie mode remains disabled by default; Basic API boundary and cross-origin denial PASS.'
