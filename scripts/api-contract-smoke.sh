#!/usr/bin/env bash
# Negative HTTP contracts against isolated Docker lab; never writes fixture records.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo "Run scripts/setup.sh first" >&2; exit 1; }
set -a; source .env; set +a
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
API=http://127.0.0.1:8080/api
output=$(mktemp)
trap 'rm -f "$output"' EXIT

expect_status() {
  local expected="$1"
  shift
  local actual
  actual=$(curl -sS -o "$output" -w '%{http_code}' "$@")
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected HTTP $expected, received $actual" >&2
    # Never log arbitrary API responses (they might include sensitive data).
    exit 1
  fi
}

before=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/summary")
expect_status 200 "$API/health/live"
expect_status 401 "$API/plans"
expect_status 401 -H "Content-Type: application/json" --data '{"name":"Unauthorized","downloadKbps":1024,"uploadKbps":256}' "$API/plans"
expect_status 403 -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "Origin: https://untrusted.invalid" -H "Content-Type: application/json" --data '{"name":"Rejected","downloadKbps":1024,"uploadKbps":256}' "$API/plans"
expect_status 403 -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "Sec-Fetch-Site: cross-site" -H "Content-Type: application/json" --data '{"name":"Rejected","downloadKbps":1024,"uploadKbps":256}' "$API/plans"
expect_status 400 -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "Content-Type: application/json" --data '{malformed JSON' "$API/plans"
expect_status 400 -u "$ADMIN_USER:$ADMIN_PASSWORD" -H "Content-Type: application/json" --data '{"name":"Invalid","downloadKbps":-1,"uploadKbps":256}' "$API/plans"
after=$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/summary")
python3 - "$before" "$after" <<'PY'
import json,sys
prior,current=(json.loads(x) for x in sys.argv[1:3])
assert prior["plans"] == current["plans"], "Negative calls mutated plans"
assert prior["labAccounts"] == current["labAccounts"], "Negative calls mutated lab users"
PY
echo "Stage 1 negative HTTP contracts PASS"
