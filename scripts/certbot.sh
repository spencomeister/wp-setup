#!/usr/bin/env bash
set -euo pipefail

# Issue / renew Let's Encrypt certs using DNS-01 via Cloudflare.
# Reuses existing certs when present.
#
# Usage:
#   bash scripts/certbot.sh issue --config config/config.yml --out out
#   bash scripts/certbot.sh renew --config config/config.yml --out out

ACTION=${1:-}
shift || true

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_PATH="$ROOT_DIR/config/config.yml"
OUT_DIR="$ROOT_DIR/out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "Usage: certbot.sh <issue|renew> [--config path] [--out dir]" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing config: $CONFIG_PATH" >&2
  exit 1
fi

SECRETS_FILE="$OUT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" && -f "$ROOT_DIR/config/secrets.env" ]]; then
  SECRETS_FILE="$ROOT_DIR/config/secrets.env"
fi
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing secrets: out/secrets.env (or config/secrets.env). Run scripts/init-secrets.sh" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a

if [[ -z "${CF_DNS_API_TOKEN:-}" ]]; then
  echo "CF_DNS_API_TOKEN is required in $SECRETS_FILE" >&2
  exit 1
fi

# Extract required values from YAML using python (keeps bash simple)
PY=${PYTHON:-python3}
readarray -t CERT_PLAN < <(
  "$PY" - <<'PY'
import sys
from pathlib import Path
import yaml

cfg_path = Path(sys.argv[1])
cfg = yaml.safe_load(cfg_path.read_text(encoding='utf-8'))

le = cfg.get('letsencrypt', {})
email = le.get('email')
le_dir = le.get('dir')
reuse = bool(le.get('reuse_existing', True))

sites = cfg.get('edge', {}).get('sites', [])
if not email or not le_dir or not sites:
    raise SystemExit('config missing letsencrypt.email/dir or edge.sites')

print(f"EMAIL={email}")
print(f"LE_DIR={le_dir}")
print(f"REUSE={'1' if reuse else '0'}")

for s in sites:
    tls = s.get('tls_domains')
    if not tls:
        continue
    # choose cert name: first non-wildcard else first
    cert_name = next((d for d in tls if not str(d).startswith('*.')), tls[0])
    tls = [str(d) for d in tls]
    print("CERT=" + cert_name + " " + " ".join(tls))
PY
  "$CONFIG_PATH"
)

EMAIL=$(printf '%s\n' "${CERT_PLAN[@]}" | awk -F= '/^EMAIL=/{print $2; exit}')
LE_DIR=$(printf '%s\n' "${CERT_PLAN[@]}" | awk -F= '/^LE_DIR=/{print $2; exit}')
REUSE=$(printf '%s\n' "${CERT_PLAN[@]}" | awk -F= '/^REUSE=/{print $2; exit}')

if [[ -z "$EMAIL" || -z "$LE_DIR" ]]; then
  echo "Failed to parse config (EMAIL/LE_DIR)." >&2
  exit 1
fi

mkdir -p "$LE_DIR"

# Fixed policy hint
if [[ "$LE_DIR" != "/srv/letsencrypt" ]]; then
  echo "Warning: letsencrypt.dir is '$LE_DIR' but fixed policy is /srv/letsencrypt" >&2
  echo "Run scripts/link-certs.sh and set letsencrypt.dir to /srv/letsencrypt" >&2
fi

CF_INI_DIR="$OUT_DIR/certbot"
mkdir -p "$CF_INI_DIR"
CF_INI="$CF_INI_DIR/cloudflare.ini"
umask 077
cat >"$CF_INI" <<EOF
# generated
dns_cloudflare_api_token = $CF_DNS_API_TOKEN
EOF

CERTBOT_IMAGE="certbot/dns-cloudflare:latest"

run_certbot() {
  docker run --rm \
    -v "$LE_DIR:/etc/letsencrypt" \
    -v "$CF_INI_DIR:/run/certbot" \
    "$CERTBOT_IMAGE" \
    "$@"
}

if [[ "$ACTION" == "renew" ]]; then
  run_certbot renew --non-interactive --agree-tos
  echo "Renew completed."
  exit 0
fi

if [[ "$ACTION" != "issue" ]]; then
  echo "Unknown action: $ACTION" >&2
  exit 2
fi

# Issue certs (skip if reuse enabled and live dir exists)
while IFS= read -r line; do
  [[ "$line" =~ ^CERT= ]] || continue
  rest=${line#CERT=}
  cert_name=${rest%% *}
  domains=${rest#* }

  if [[ "$REUSE" == "1" && -f "$LE_DIR/live/$cert_name/fullchain.pem" ]]; then
    echo "Reuse existing cert: $cert_name"
    continue
  fi

  args=(
    certonly
    --non-interactive
    --agree-tos
    --email "$EMAIL"
    --dns-cloudflare
    --dns-cloudflare-credentials /run/certbot/cloudflare.ini
    --dns-cloudflare-propagation-seconds 30
  )

  for d in $domains; do
    args+=( -d "$d" )
  done

  echo "Issuing cert: $cert_name ($domains)"
  run_certbot "${args[@]}"
done < <(printf '%s\n' "${CERT_PLAN[@]}")

echo "Issue completed."
