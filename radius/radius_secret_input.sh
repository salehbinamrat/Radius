#!/usr/bin/env bash
# Strict secret inputs and atomic configuration publication, using existing system tools.
set +x
set -euo pipefail
export LC_ALL=C

load_hex() {
  local name="$1" filevar inline file raw value='' i byte
  [[ "$name" == DB_PASSWORD || "$name" == RADIUS_SECRET ]] || return 1
  filevar="${name}_FILE"
  inline="${!name-}"
  if [[ -v $filevar ]]; then
    file="${!filevar}"
    [[ -z "$inline" && "$file" == /* && -f "$file" ]] || return 1
    # Bash strings discard NUL bytes; inspect bounded raw bytes before decoding.
    raw=$(od -An -v -tx1 -N 51 "$file" 2>/dev/null) || return 1
    raw="${raw//[[:space:]]/}"
    [[ "$raw" =~ ^(3[0-9]|6[1-6]){48}(0a|0d0a)?$ ]] || return 1
    for ((i=0;i<96;i+=2)); do
      printf -v byte '%b' "\\x${raw:i:2}"
      value+="$byte"
    done
  else
    value="$inline"
  fi
  [[ "$value" =~ ^[a-f0-9]{48}$ ]] || return 1
  printf '%s\n' "$value"
}

ipv4_number() {
  local address="$1" octet number=0
  local -a octets
  [[ "$address" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
    number=$((number * 256 + 10#$octet))
  done
  printf '%s\n' "$number"
}

valid_cidr() {
  local cidr="$1" address mask n inverse
  [[ "$cidr" =~ ^[0-9./]+$ ]] || return 1
  address="${cidr%%/*}"
  ipv4_number "$address" >/dev/null || return 1
  [[ "$cidr" == */* ]] || return 0
  mask="${cidr#*/}"
  if [[ "$mask" =~ ^0*([0-9]|[12][0-9]|3[0-2])$ ]]; then return 0; fi
  n=$(ipv4_number "$mask") || return 1
  inverse=$((4294967295 ^ n))
  # Python IPv4Network accepts contiguous netmasks and hostmasks.
  (( (n & (n+1)) == 0 || (inverse & (inverse+1)) == 0 ))
}

publish_config() {
  local dest="$1" content="$2" temp
  umask 077
  temp=$(mktemp "${dest%/*}/.radius-config-XXXXXX") || return 1
  if ! chown root:freerad "$temp" || ! chmod 640 "$temp" ||
     ! printf '%s' "$content" > "$temp" || ! mv -f -- "$temp" "$dest"; then
    rm -f -- "$temp"
    return 1
  fi
}

render() {
  local db secret user cidr sql clients
  db=$(load_hex DB_PASSWORD) || return 1
  secret=$(load_hex RADIUS_SECRET) || return 1
  user="${RADIUS_DB_USER-radius}"
  cidr="${RADIUS_CLIENT_CIDR-}"
  [[ "$user" == radius || "$user" == radius_runtime ]] || return 1
  valid_cidr "$cidr" || return 1
  # Keep exact trailing newlines. No secret values in external command arguments.
  sql=$(cat /opt/radius/sql.template && printf x) || return 1
  clients=$(cat /opt/radius/clients.template && printf x) || return 1
  sql="${sql%x}"; clients="${clients%x}"
  [[ "$sql" == *__DB_PASSWORD__* && "$sql" == *__DB_USER__* &&
     "$clients" == *__RADIUS_SECRET__* && "$clients" == *__RADIUS_CLIENT_CIDR__* ]] || return 1
  sql="${sql//__DB_PASSWORD__/$db}"; sql="${sql//__DB_USER__/$user}"
  clients="${clients//__RADIUS_SECRET__/$secret}"; clients="${clients//__RADIUS_CLIENT_CIDR__/$cidr}"
  publish_config /etc/freeradius/3.0/mods-available/sql "$sql" || return 1
  publish_config /etc/freeradius/3.0/clients.conf "$clients"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# == 1 ]]; then
    if [[ "$1" == render ]]; then
      if render 2>/dev/null; then exit 0; fi
    elif load_hex "$1"; then exit 0
    fi
  fi
  echo 'RADIUS secret or configuration input rejected' >&2
  exit 1
fi
