#!/usr/bin/env bash
# Shared native image configuration: build-time and disposable source probe.
set -euo pipefail
# Rewrite only the two pinned upstream directives, without Python.
# Validate both before publication; keep the original mode/owner and bytes
# of unrelated lines. Sourcing this file defines the helper only.
rewrite_native_security_config() (
  set +x
  local file="$1" tmp line suffix name user_count=0 group_count=0
  [[ -f "$file" && ! -L "$file" ]] || return 1
  umask 077
  tmp=$(mktemp "${file%/*}/.radius-native-XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  # Preserve the original mode and ownership with Alpine/BusyBox cp -p.
  cp -p -- "$file" "$tmp" || return 1
  while :; do
    line=
    if IFS= read -r line; then
      suffix=$'\n'
    elif [[ -n "$line" ]]; then
      suffix=
    else
      break
    fi
    if [[ "$line" =~ ^[[:blank:]]*#[[:blank:]]*user[[:blank:]]*=[[:blank:]]*radius[[:blank:]]*$ ]]; then
      user_count=$((user_count+1))
      line=$'\tuser = freerad'
    elif [[ "$line" =~ ^[[:blank:]]*#[[:blank:]]*group[[:blank:]]*=[[:blank:]]*radius[[:blank:]]*$ ]]; then
      group_count=$((group_count+1))
      line=$'\tgroup = freerad'
    fi
    printf '%s%s' "$line" "$suffix" || return 1
  done <"$file" >"$tmp"
  if [[ "$user_count" != 1 || "$group_count" != 1 ]]; then
    echo 'Upstream security configuration changed: expected exactly one user and group directive' >&2
    return 1
  fi
  mv -f -- "$tmp" "$file" || return 1
)
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi
if ! grep -q '^freerad:' /etc/group; then addgroup -S freerad; fi
if ! id freerad >/dev/null 2>&1; then adduser -S -D -H -G freerad freerad; fi
mkdir -p /etc/freeradius
ln -s /opt/etc/raddb /etc/freeradius/3.0
mkdir -p /opt/var/run/radiusd /opt/var/log/radius/radacct
chown -R freerad:freerad /opt/var
# The upstream image uses its own configuration ownership/modes. The
# application runs as freerad, so normalize only this disposable native
# configuration tree (never symlink targets outside it). Keep root as owner,
# allow the daemon group to read/traverse, and deny group writes/world access.
config=/opt/etc/raddb
find "$config" -type d -exec chown root:freerad {} +
find "$config" -type d -exec chmod 0750 {} +
find "$config" -type f -exec chown root:freerad {} +
find "$config" -type f -exec chmod u=rwX,g=rX,o= {} +
# Regress the actual failure as the daemon identity before loading radiusd.
# Do not substitute a root read check, or weaken the subsequent SQL probe.
if ! su -s /bin/sh -c '
  test -x /opt/etc/raddb &&
  test ! -w /opt/etc/raddb &&
  test -r /opt/etc/raddb/radiusd.conf &&
  test -r /opt/etc/raddb/mods-config/preprocess/huntgroups &&
  test ! -w /opt/etc/raddb/mods-config/preprocess/huntgroups
' freerad; then
  echo 'Native FreeRADIUS configuration permissions preflight failed' >&2
  stat -c '%a %u:%g %n' "$config" "$config/mods-config/preprocess/huntgroups" >&2
  exit 1
fi
echo 'Native configuration readable by non-root daemon and not writable PASS'
# Use upstream's native security settings, not a root-only test.
rewrite_native_security_config "$config/radiusd.conf"
# Verify permissions after atomic replacement under the actual daemon identity.
su -s /bin/sh -c 'test -r /opt/etc/raddb/radiusd.conf && test ! -w /opt/etc/raddb/radiusd.conf' freerad
echo 'Native security configuration prepared without Python PASS'
