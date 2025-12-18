#!/usr/bin/env bash
set -euo pipefail

# Manage Cloudflare DNS records for this stack.
#
# This is OPTIONAL but helpful to avoid "DNS未設定" issues.
# Requires a Cloudflare API token with Zone:Read + DNS:Edit.
# Token should be placed in config/secrets.env as CF_DNS_API_TOKEN=... (or the env name configured).
#
# Usage:
#   bash scripts/cloudflare-dns.sh plan  --config config/config.yml
#   bash scripts/cloudflare-dns.sh apply --config config/config.yml

ACTION=${1:-}
shift || true

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_PATH="$ROOT_DIR/config/config.yml"
SECRETS_PATH="$ROOT_DIR/config/secrets.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2;;
    --secrets) SECRETS_PATH="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$ACTION" || ( "$ACTION" != "plan" && "$ACTION" != "apply" ) ]]; then
  echo "Usage: cloudflare-dns.sh <plan|apply> [--config path] [--secrets path]" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing config: $CONFIG_PATH" >&2
  exit 1
fi

if [[ -f "$SECRETS_PATH" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$SECRETS_PATH"
  set +a
fi

PY=${PYTHON:-python3}
SCRIPT="$ROOT_DIR/scripts/cloudflare_dns.py"

if [[ "$ACTION" == "apply" ]]; then
  "$PY" "$SCRIPT" --config "$CONFIG_PATH" --secrets "$SECRETS_PATH" --apply
else
  "$PY" "$SCRIPT" --config "$CONFIG_PATH" --secrets "$SECRETS_PATH"
fi
