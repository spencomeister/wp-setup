#!/usr/bin/env bash
set -euo pipefail

# Generates secrets.env automatically (DB passwords + WP admin password)
# and logs generated values to a log file (as requested).
#
# Output:
# - config/secrets.env (canonical)
# - out/secrets.env (copied if out/ exists)
# - logs/secrets-<timestamp>.log (contains generated secrets)

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_PATH=${CONFIG_PATH:-"$ROOT_DIR/config/config.yml"}
SECRETS_EXAMPLE=${SECRETS_EXAMPLE:-"$ROOT_DIR/config/secrets.env.example"}
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/out"}
LOG_DIR=${LOG_DIR:-"$ROOT_DIR/logs"}

mkdir -p "$OUT_DIR" "$LOG_DIR"

TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/secrets-$TS.log"

CONFIG_SECRETS_FILE="$ROOT_DIR/config/secrets.env"
SECRETS_FILE="$CONFIG_SECRETS_FILE"

if [[ ! -f "$SECRETS_EXAMPLE" ]]; then
  echo "Missing secrets.env.example: $SECRETS_EXAMPLE" >&2
  exit 1
fi

# Create secrets.env if missing
if [[ ! -f "$SECRETS_FILE" ]]; then
  cp "$SECRETS_EXAMPLE" "$SECRETS_FILE"
fi

chmod 600 "$SECRETS_FILE" || true

# Always create the log file (even if nothing changes)
: >"$LOG_FILE"
chmod 600 "$LOG_FILE" || true

# Generate random base64-ish token (no trailing '=')
rand() {
  # 32 bytes -> 43-ish chars when base64
  openssl rand -base64 32 | tr -d '=\n'
}

set_kv_if_empty() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$SECRETS_FILE"; then
    local current
    current=$(grep -E "^${key}=" "$SECRETS_FILE" | head -n1 | cut -d= -f2-)
    if [[ -z "${current}" ]]; then
      # replace in-place
      sed -i "s|^${key}=.*|${key}=${value}|" "$SECRETS_FILE"
      echo "${key}=${value}" >>"$LOG_FILE"
    fi
  else
    echo "${key}=${value}" >>"$SECRETS_FILE"
    echo "${key}=${value}" >>"$LOG_FILE"
  fi
}

# Cloudflare token is not generated
# Required secrets (auto)
set_kv_if_empty "WP_A_DB_ROOT_PASSWORD" "$(rand)"
set_kv_if_empty "WP_A_DB_PASSWORD" "$(rand)"
set_kv_if_empty "WP_B_DB_ROOT_PASSWORD" "$(rand)"
set_kv_if_empty "WP_B_DB_PASSWORD" "$(rand)"
set_kv_if_empty "ZBX_DB_PASSWORD" "$(rand)"

# WordPress admin credentials (generated)
set_kv_if_empty "WP_ADMIN_USER" "admin"
set_kv_if_empty "WP_ADMIN_PASSWORD" "$(rand)"
set_kv_if_empty "WP_ADMIN_EMAIL" "admin@example.com"

echo "Wrote: $SECRETS_FILE"
echo "Logged generated secrets to: $LOG_FILE"
echo "NOTE: This log contains passwords (requested). Protect it appropriately."

# Copy into out/ for docker compose (render.py may recreate out/)
if [[ -d "$OUT_DIR" ]]; then
  cp "$SECRETS_FILE" "$OUT_DIR/secrets.env"
  chmod 600 "$OUT_DIR/secrets.env" || true
  echo "Copied to: $OUT_DIR/secrets.env"
fi
