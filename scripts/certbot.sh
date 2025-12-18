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
FORCE_REISSUE=0
RELOAD_EDGE=0
ONLY_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    --force) FORCE_REISSUE=1; shift;;
    --reload-edge) RELOAD_EDGE=1; shift;;
    --only-type) ONLY_TYPE="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "Usage: certbot.sh <issue|renew> [--config path] [--out dir] [--force] [--reload-edge] [--only-type wordpress|zabbix]" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing config: $CONFIG_PATH" >&2
  exit 1
fi

# Normalize OUT_DIR to an absolute path for docker bind mounts.
# If OUT_DIR is relative (e.g. "out"), docker may treat it as a *named volume*.
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd -P)

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
  ONLY_TYPE="$ONLY_TYPE" "$PY" - "$CONFIG_PATH" <<'PY'
import sys
import os
from pathlib import Path
try:
    import yaml
except Exception as e:
    raise SystemExit(
        "PyYAML is required. Install: sudo apt-get install -y python3-yaml\n"
        "(or: python3 -m pip install pyyaml)"
    ) from e

if len(sys.argv) < 2:
  raise SystemExit('Internal error: missing config path argument')

cfg_path = Path(sys.argv[1])
cfg = yaml.safe_load(cfg_path.read_text(encoding='utf-8'))

only_type = (os.environ.get('ONLY_TYPE') or '').strip().lower()
if only_type and only_type not in {'wordpress', 'zabbix'}:
  raise SystemExit(f"Invalid --only-type: {only_type}")

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
  if only_type and str(s.get('type') or '').strip().lower() != only_type:
    continue
    tls = s.get('tls_domains')
    if not tls:
        continue
    # choose cert name: first non-wildcard else first
    cert_name = next((d for d in tls if not str(d).startswith('*.')), tls[0])
    tls = [str(d) for d in tls]
    print("CERT=" + cert_name + " " + " ".join(tls))
PY
)

# If no CERT lines were produced, we did not schedule any issuance.
# This often means:
# - edge.sites has no matching type (e.g. zabbix removed)
# - tls_domains is empty/missing
# - --only-type value doesn't match
if ! printf '%s\n' "${CERT_PLAN[@]}" | grep -q '^CERT='; then
  if [[ -n "$ONLY_TYPE" ]]; then
    echo "No certs planned for --only-type '$ONLY_TYPE'." >&2
  else
    echo "No certs planned (no edge.sites[*].tls_domains found)." >&2
  fi
  echo "Check config: edge.sites[*].type and edge.sites[*].tls_domains" >&2
  exit 1
fi

EMAIL=$(printf '%s\n' "${CERT_PLAN[@]}" | awk -F= '/^EMAIL=/{print $2; exit}')
LE_DIR=$(printf '%s\n' "${CERT_PLAN[@]}" | awk -F= '/^LE_DIR=/{print $2; exit}')
REUSE=$(printf '%s\n' "${CERT_PLAN[@]}" | awk -F= '/^REUSE=/{print $2; exit}')

if [[ -z "$EMAIL" || -z "$LE_DIR" ]]; then
  echo "Failed to parse config (EMAIL/LE_DIR)." >&2
  exit 1
fi

# Guard against placeholder emails that Let's Encrypt rejects.
if [[ "$EMAIL" == "admin@example.com" || "$EMAIL" == *@example.com || "$EMAIL" == *@example.net || "$EMAIL" == *@example.org ]]; then
  echo "Invalid letsencrypt.email in config: '$EMAIL'" >&2
  echo "Set a real email address in config/config.yml (letsencrypt.email), then retry." >&2
  exit 1
fi

mkdir -p "$LE_DIR"

# Normalize LE_DIR to an absolute path as well.
LE_DIR=$(cd "$LE_DIR" && pwd -P)

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

reload_edge_best_effort() {
  # Cloudflare Full(strict) will fail (526) if the origin serves an expired/mismatched cert.
  # Certbot renew updates files on disk, but Nginx needs a reload to pick up the new cert.
  # Do a best-effort reload when compose is available.
  local compose_file="$OUT_DIR/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    return 0
  fi

  # Prefer secrets in out/ when present.
  local env_file="$OUT_DIR/secrets.env"
  if [[ ! -f "$env_file" && -f "$ROOT_DIR/config/secrets.env" ]]; then
    env_file="$ROOT_DIR/config/secrets.env"
  fi

  if command -v docker >/dev/null 2>&1; then
    docker compose -f "$compose_file" --env-file "$env_file" exec -T edge nginx -s reload >/dev/null 2>&1 || true
  fi
}

if [[ "$ACTION" == "renew" ]]; then
  run_certbot renew --non-interactive --agree-tos
  if [[ "$RELOAD_EDGE" == "1" ]]; then
    reload_edge_best_effort
  fi
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

  if [[ "$REUSE" == "1" && "$FORCE_REISSUE" != "1" && -f "$LE_DIR/live/$cert_name/fullchain.pem" ]]; then
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

  # Force re-issue even if a cert exists (useful when domains changed / Cloudflare 526 due to mismatch).
  if [[ "$FORCE_REISSUE" == "1" ]]; then
    args+=( --force-renewal --cert-name "$cert_name" )
  fi

  for d in $domains; do
    args+=( -d "$d" )
  done

  echo "Issuing cert: $cert_name ($domains)"
  run_certbot "${args[@]}"
done < <(printf '%s\n' "${CERT_PLAN[@]}")

if [[ "$RELOAD_EDGE" == "1" ]]; then
  reload_edge_best_effort
fi

echo "Issue completed."
