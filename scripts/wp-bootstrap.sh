#!/usr/bin/env bash
set -euo pipefail

# Bootstrap WordPress (core install + multisite subdomain) for both stacks.
# - Generates nothing itself; expects out/ created by render.py
# - Expects out/secrets.env created by init-secrets.sh
# - Logs generated secrets are handled by init-secrets.sh

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/out"}
COMPOSE_FILE="$OUT_DIR/docker-compose.yml"
SECRETS_FILE="$OUT_DIR/secrets.env"
CONFIG_PATH=${CONFIG_PATH:-"$ROOT_DIR/config/config.yml"}

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Missing $COMPOSE_FILE (run scripts/render.py)" >&2
  exit 1
fi
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing $SECRETS_FILE (run scripts/init-secrets.sh)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a

PY=${PYTHON:-python3}

# Read apex domains from config
readarray -t APEXS < <(
  "$PY" - <<'PY'
import sys
from pathlib import Path
import yaml

cfg = yaml.safe_load(Path(sys.argv[1]).read_text(encoding='utf-8'))

apexes = []
for s in cfg.get('edge', {}).get('sites', []):
    if s.get('type') == 'wordpress':
        apex = s.get('apex_domain')
        if apex:
            apexes.append(str(apex))

if len(apexes) < 2:
    raise SystemExit('need two wordpress sites in edge.sites')

print(apexes[0])
print(apexes[1])
PY
  "$CONFIG_PATH"
)

APEX_A=${APEXS[0]}
APEX_B=${APEXS[1]}

ADMIN_USER=${WP_ADMIN_USER:-admin}
ADMIN_PASS=${WP_ADMIN_PASSWORD:-}
ADMIN_EMAIL=${WP_ADMIN_EMAIL:-admin@example.com}

if [[ -z "$ADMIN_PASS" ]]; then
  echo "WP_ADMIN_PASSWORD is empty; run scripts/init-secrets.sh" >&2
  exit 1
fi

run_wp() {
  local stack="$1"      # wp-a or wp-b
  local apex="$2"       # example.com
  local db_host="$3"    # wp-a-db
  local db_user="$4"    # wordpress
  local db_pass_var="$5"# WP_A_DB_PASSWORD
  local url="https://$apex"

  # Resolve DB password from env var name
  local db_pass=${!db_pass_var}
  if [[ -z "$db_pass" ]]; then
    echo "Missing $db_pass_var in secrets.env" >&2
    exit 1
  fi

  echo "--- Bootstrapping $stack ($url) ---"

  # Download WordPress if not present
  docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" run --rm "$stack-cli" \
    sh -lc "test -f wp-settings.php || wp core download --path=/var/www/html --force"

  # Create wp-config.php if missing
  docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" run --rm "$stack-cli" \
    sh -lc "test -f wp-config.php || wp config create --path=/var/www/html \
      --dbname=wordpress --dbuser=$db_user --dbpass='$db_pass' --dbhost=$db_host \
      --skip-check --force"

  # Install core if not installed
  docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" run --rm "$stack-cli" \
    sh -lc "wp core is-installed --path=/var/www/html || wp core install --path=/var/www/html \
      --url='$url' --title='WordPress ($apex)' \
      --admin_user='$ADMIN_USER' --admin_password='$ADMIN_PASS' --admin_email='$ADMIN_EMAIL'"

  # Enable multisite (subdomain) if not already
  docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" run --rm "$stack-cli" \
    sh -lc "wp config get MULTISITE --path=/var/www/html >/dev/null 2>&1 || wp core multisite-convert --path=/var/www/html --subdomains --title='Network ($apex)'"

  echo "OK: $stack"
}

run_wp "wp-a" "$APEX_A" "wp-a-db" "wordpress" "WP_A_DB_PASSWORD"
run_wp "wp-b" "$APEX_B" "wp-b-db" "wordpress" "WP_B_DB_PASSWORD"

echo "Bootstrap complete."
echo "Admin user: $ADMIN_USER"
echo "Admin email: $ADMIN_EMAIL"
echo "Admin password is in out/secrets.env and also logged by init-secrets.sh (requested)."
