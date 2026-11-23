#!/usr/bin/env bash
# LAB ONLY: encrypted PostgreSQL snapshot, never overwrite an existing archive.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "${LAB_BACKUP_ACK:-}" == "isolated-lab" ]] || { echo "LAB_BACKUP_ACK=isolated-lab is required" >&2; exit 1; }
[[ $# -eq 1 && "$1" == /* && "$1" == *.pgp ]] || { echo "Usage: lab-backup.sh /absolute/private/path/snapshot.pgp" >&2; exit 1; }
dest="$1"
[[ ! -e "$dest" && ! -L "$dest" && ! -e "$dest.sha256" ]] || { echo "Backup already exists; refusing overwrite" >&2; exit 1; }
[[ -d "$(dirname "$dest")" ]] || { echo "Backup directory does not exist" >&2; exit 1; }
[[ -f .env ]] || { echo "Run scripts/setup.sh for the isolated lab first" >&2; exit 1; }
[[ -n "${BACKUP_PASSPHRASE_FILE:-}" && -f "$BACKUP_PASSPHRASE_FILE" && ! -L "$BACKUP_PASSPHRASE_FILE" ]] || { echo "Private BACKUP_PASSPHRASE_FILE required" >&2; exit 1; }
mode=$(stat -c %a "$BACKUP_PASSPHRASE_FILE")
[[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0077) == 0 )) || { echo "Passphrase file must not be group/world readable" >&2; exit 1; }
[[ -s "$BACKUP_PASSPHRASE_FILE" ]] || { echo "Passphrase file must not be empty" >&2; exit 1; }
command -v gpg >/dev/null || { echo "Install GnuPG before proceeding" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }
umask 077
partial=$(mktemp "$(dirname "$dest")/.radius-encrypted-partial.XXXXXXXX")
trap 'rm -f -- "$partial"' EXIT
# Stream directly into GnuPG, avoiding an unencrypted backup file on the host.
docker compose exec -T db pg_dump -U radius -d radius --format=custom --no-owner --no-acl |
  gpg --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
    --passphrase-file "$BACKUP_PASSPHRASE_FILE" --symmetric --cipher-algo AES256 \
    --compress-algo none --output "$partial"
[[ -s "$partial" ]] || { echo "Encrypted backup is empty" >&2; exit 1; }
chmod 600 "$partial"
# Use a hard link in the destination directory for atomic no-clobber publication.
ln "$partial" "$dest"
rm -f -- "$partial"
printf "%s  %s\n" "$(sha256sum "$dest" | cut -d ' ' -f1)" "$dest" > "$dest.sha256"
chmod 600 "$dest.sha256"
echo "Encrypted lab backup and SHA-256 manifest created; restore verification is still required."
