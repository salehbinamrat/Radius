#!/usr/bin/env bash
# Only Docker's scheduled healthcheck publishes; manual probes do not alter evidence.
set -euo pipefail
state=no-response
if /usr/local/bin/radius-health-probe.sh; then state=responsive; fi
dir=/var/lib/radius-health
umask 077
tmp=$(mktemp "$dir/.status.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf '%s %s\n' "$(date -u +%s)" "$state" > "$tmp"
chmod 644 "$tmp"
mv -f -- "$tmp" "$dir/status"
[[ "$state" == responsive ]]
