#!/usr/bin/env bash
set -euo pipefail

# One-shot runner for this repo.
# Assumes config/config.yml and config/secrets.env are already prepared.
#
# Flags:
#   --create
#   --scrap
#   --scrap-and-recreate
#
# Optional:
#   --config <path>
#   --out <dir>

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

MODE=""
CONFIG_PATH="$ROOT_DIR/config/config.yml"
OUT_DIR="$ROOT_DIR/out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) MODE="create"; shift;;
    --scrap) MODE="scrap"; shift;;
    --scrap-and-recreate) MODE="scrap-and-recreate"; shift;;
    --config) CONFIG_PATH="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    -h|--help)
      cat <<'USAGE'
Usage:
  bash scripts/run.sh --create [--config path] [--out dir]
  bash scripts/run.sh --scrap  [--config path] [--out dir]
  bash scripts/run.sh --scrap-and-recreate [--config path] [--out dir]

Notes:
- Requires: config/config.yml, config/secrets.env
- --scrap removes Docker volumes (DB/WP data). Certificates under /srv/letsencrypt are not removed.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Missing mode. Use --create / --scrap / --scrap-and-recreate" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing config: $CONFIG_PATH" >&2
  exit 1
fi

scrap() {
  # Try to bring down the stack even if out/ doesn't exist.
  if [[ -f "$OUT_DIR/docker-compose.yml" ]]; then
    docker compose -f "$OUT_DIR/docker-compose.yml" down -v --remove-orphans || true
  elif [[ -d "$OUT_DIR" ]]; then
    (cd "$OUT_DIR" && docker compose down -v --remove-orphans) || true
  else
    echo "No out dir found: $OUT_DIR (nothing to scrap)"
    return 0
  fi

  echo "Scrap completed (volumes removed)."
}

create() {
  # 1) Render output
  python3 "$ROOT_DIR/scripts/render.py" --config "$CONFIG_PATH" --out "$OUT_DIR"

  # 2) Secrets generation (fills missing values only)
  OUT_DIR="$OUT_DIR" CONFIG_PATH="$CONFIG_PATH" bash "$ROOT_DIR/scripts/init-secrets.sh"

  # 3) (Optional) Cloudflare DNS apply (only if enabled; also no token needed if disabled)
  bash "$ROOT_DIR/scripts/cloudflare-dns.sh" apply --config "$CONFIG_PATH" --secrets "$ROOT_DIR/config/secrets.env" || true

  # 4) Certs link + issue
  bash "$ROOT_DIR/scripts/link-certs.sh"
  bash "$ROOT_DIR/scripts/certbot.sh" issue --config "$CONFIG_PATH" --out "$OUT_DIR"

  # 5) Bring up
  docker compose -f "$OUT_DIR/docker-compose.yml" --env-file "$OUT_DIR/secrets.env" up -d

  # 6) WordPress bootstrap
  bash "$ROOT_DIR/scripts/wp-bootstrap.sh" --config "$CONFIG_PATH" --out "$OUT_DIR" || bash "$ROOT_DIR/scripts/wp-bootstrap.sh"

  echo "Create completed."
}

case "$MODE" in
  scrap)
    scrap
    ;;
  create)
    create
    ;;
  scrap-and-recreate)
    scrap
    create
    ;;
  *)
    echo "Internal error: unknown mode '$MODE'" >&2
    exit 2
    ;;
esac
