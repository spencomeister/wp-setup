#!/usr/bin/env bash
set -euo pipefail

# Recreate ONLY the Zabbix part (config → cert → compose up).
# Intended use-case: change Zabbix public domain (e.g. avoid 2-level subdomain that Cloudflare TLS can't serve).
#
# What this does:
# - Re-renders out/
# - Ensures secrets exist (fills missing values only)
# - (Optional) applies Cloudflare DNS if enabled
# - Issues/renews ONLY the zabbix certs (type=zabbix)
# - Brings up edge + zabbix containers
#
# Notes:
# - edge config includes ALL sites; if other sites reference missing certs, edge may fail to start.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

CONFIG_PATH="$ROOT_DIR/config/config.yml"
OUT_DIR="$ROOT_DIR/out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    -h|--help)
      cat <<'USAGE'
Usage:
  bash scripts/zabbix-recreate.sh [--config path] [--out dir]

Example:
  bash scripts/zabbix-recreate.sh --config config/config.yml --out out
USAGE
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing config: $CONFIG_PATH" >&2
  exit 1
fi

# 1) Render output
python3 "$ROOT_DIR/scripts/render.py" --config "$CONFIG_PATH" --out "$OUT_DIR"

# 2) Secrets generation (fills missing values only)
OUT_DIR="$OUT_DIR" CONFIG_PATH="$CONFIG_PATH" bash "$ROOT_DIR/scripts/init-secrets.sh"

# 3) (Optional) Cloudflare DNS apply
bash "$ROOT_DIR/scripts/cloudflare-dns.sh" apply --config "$CONFIG_PATH" --secrets "$ROOT_DIR/config/secrets.env" || true

# 4) Certs link (best effort)
if [[ ${EUID:-0} -eq 0 ]]; then
  bash "$ROOT_DIR/scripts/link-certs.sh"
else
  echo "[WARN] Not running as root; skipping scripts/link-certs.sh (run once with sudo if needed)." >&2
fi

# 5) Issue ONLY Zabbix certs (force re-issue to reflect domain changes)
# NOTE: Do NOT reload edge here; edge might not be up yet.
bash "$ROOT_DIR/scripts/certbot.sh" issue --config "$CONFIG_PATH" --out "$OUT_DIR" --only-type zabbix --force

# 6) Bring up edge + zabbix
docker compose -f "$OUT_DIR/docker-compose.yml" --env-file "$OUT_DIR/secrets.env" up -d edge zbx-db zbx-server zbx-web

# 7) Reload edge to pick up new certs (best effort)
docker compose -f "$OUT_DIR/docker-compose.yml" --env-file "$OUT_DIR/secrets.env" exec -T edge nginx -s reload || true

echo "Zabbix recreate completed."
