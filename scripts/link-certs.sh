#!/usr/bin/env bash
set -euo pipefail

# Fixed policy:
# - Canonical cert directory: /srv/letsencrypt
# - Provide /etc/letsencrypt as a symlink -> /srv/letsencrypt
# This satisfies the "ln する" requirement and keeps a stable mount path.

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

CANONICAL=/srv/letsencrypt
LEGACY=/etc/letsencrypt

mkdir -p /srv
mkdir -p "$CANONICAL"
chmod 700 "$CANONICAL" || true

# If /etc/letsencrypt is a real dir (not symlink), migrate contents once.
if [[ -d "$LEGACY" && ! -L "$LEGACY" ]]; then
  # If canonical is empty, move contents.
  if [[ -z "$(ls -A "$CANONICAL" 2>/dev/null || true)" ]]; then
    shopt -s dotglob
    if [[ -n "$(ls -A "$LEGACY" 2>/dev/null || true)" ]]; then
      mv "$LEGACY"/* "$CANONICAL"/ || true
    fi
    shopt -u dotglob
  fi

  rmdir "$LEGACY" 2>/dev/null || true
fi

# Ensure /etc/letsencrypt is a symlink to canonical
if [[ -L "$LEGACY" ]]; then
  ln -sfn "$CANONICAL" "$LEGACY"
else
  # If it still exists as file/dir, remove it (best-effort) then link.
  if [[ -e "$LEGACY" ]]; then
    rm -rf "$LEGACY"
  fi
  ln -s "$CANONICAL" "$LEGACY"
fi

echo "OK: $LEGACY -> $CANONICAL"
