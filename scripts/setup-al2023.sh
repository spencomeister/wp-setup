#!/usr/bin/env bash
set -euo pipefail

# Amazon Linux 2023 minimal bootstrap
# - TZ Asia/Tokyo
# - Locale English
# - NTP ntp.nict.jp (chrony)
# - Docker Engine
# - Zabbix Agent (optional)

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

TZ_NAME=${TZ_NAME:-Asia/Tokyo}
LOCALE_NAME=${LOCALE_NAME:-en_US.UTF-8}
NTP_SERVER=${NTP_SERVER:-ntp.nict.jp}
INSTALL_ZABBIX_AGENT=${INSTALL_ZABBIX_AGENT:-1}

echo "[1/6] Timezone"
timedatectl set-timezone "$TZ_NAME"

echo "[2/6] Locale"
localectl set-locale LANG="$LOCALE_NAME" || true

echo "[3/6] NTP (chrony)"
dnf install -y chrony
sed -i "s/^pool .*/server ${NTP_SERVER} iburst/" /etc/chrony.conf || true
systemctl enable --now chronyd
systemctl restart chronyd

echo "[4/6] Docker"
dnf install -y docker
systemctl enable --now docker

echo "[5/6] docker-compose (plugin)"
# AL2023 may not ship docker compose plugin by default.
# Prefer installing 'docker-compose-plugin' if available.
if dnf list -y docker-compose-plugin >/dev/null 2>&1; then
  dnf install -y docker-compose-plugin
elif dnf list -y docker-compose >/dev/null 2>&1; then
  dnf install -y docker-compose
else
  echo "Warning: docker-compose not installed. Install manually if needed." >&2
fi

echo "[6/6] Zabbix Agent (optional)"
if [[ "$INSTALL_ZABBIX_AGENT" == "1" ]]; then
  # Zabbix repo RPM (major pinned to 7.0 as default)
  ZABBIX_RPM=/tmp/zabbix-release.rpm
  curl -fsSL -o "$ZABBIX_RPM" https://repo.zabbix.com/zabbix/7.0/alma/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm || true
  if [[ -f "$ZABBIX_RPM" ]]; then
    rpm -Uvh "$ZABBIX_RPM" || true
    dnf clean all
    dnf install -y zabbix-agent2
    systemctl enable --now zabbix-agent2
  else
    echo "Skipped: could not download zabbix-release RPM." >&2
  fi
fi

echo "Done"
