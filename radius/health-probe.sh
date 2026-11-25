#!/usr/bin/env bash
# A Status-Server packet checks the local RADIUS engine, not subscriber access.
# No external destinations, no credentials on argv, no packet dumps to logs.
set -euo pipefail
umask 077
secret_file=$(mktemp)
trap 'rm -f -- "$secret_file"' EXIT
bash /opt/radius/radius_secret_input.sh RADIUS_SECRET > "$secret_file"
# radclient verifies the response against the request and shared secret.
# A valid Access-Accept is required; timeout, reject and malformed packets fail.
if ! reply=$(printf 'Message-Authenticator = 0x00\n' |
    timeout 4s radclient -x -r 1 -t 2 -S "$secret_file" 127.0.0.1:1812 status 2>&1); then
  exit 1
fi
grep -Eq '^Received Access-Accept([[:space:]]|$)' <<< "$reply"
