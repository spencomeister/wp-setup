#!/usr/bin/env bash
set -euo pipefail

# Ubuntu 25.04 minimal bootstrap
# - TZ Asia/Tokyo
# - Locale English
# - NTP ntp.nict.jp (systemd-timesyncd)
# - Docker Engine + compose plugin
# - Zabbix Agent (optional; installs from Zabbix repo)

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

TZ_NAME=${TZ_NAME:-Asia/Tokyo}
LOCALE_NAME=${LOCALE_NAME:-en_US.UTF-8}
NTP_SERVER=${NTP_SERVER:-ntp.nict.jp}
INSTALL_ZABBIX_AGENT=${INSTALL_ZABBIX_AGENT:-1}

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Timezone"
timedatectl set-timezone "$TZ_NAME"

echo "[2/6] Locale"
apt-get update
apt-get install -y --no-install-recommends locales
sed -i "s/^# \(${LOCALE_NAME}.*\)$/\1/" /etc/locale.gen || true
locale-gen "$LOCALE_NAME"
update-locale LANG="$LOCALE_NAME"

echo "[3/6] NTP (systemd-timesyncd)"
apt-get install -y --no-install-recommends systemd-timesyncd
mkdir -p /etc/systemd/timesyncd.conf.d
cat >/etc/systemd/timesyncd.conf.d/99-wp-setup.conf <<EOF
[Time]
NTP=${NTP_SERVER}
EOF
systemctl enable --now systemd-timesyncd
systemctl restart systemd-timesyncd

echo "[4/6] Docker Engine + Compose plugin"
apt-get install -y --no-install-recommends ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

. /etc/os-release
ARCH=$(dpkg --print-architecture)
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

apt-get update
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "[5/6] Zabbix Agent (optional)"
if [[ "$INSTALL_ZABBIX_AGENT" == "1" ]]; then
  # Zabbix 7.0 LTS repo (adjust if you need a different major)
  ZABBIX_DEB=/tmp/zabbix-release.deb
  curl -fsSL -o "$ZABBIX_DEB" https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu${VERSION_ID}_all.deb || true
  if [[ -f "$ZABBIX_DEB" ]]; then
    dpkg -i "$ZABBIX_DEB" || true
    apt-get update
    apt-get install -y --no-install-recommends zabbix-agent2
    systemctl enable --now zabbix-agent2
  else
    echo "Skipped: could not download zabbix-release for this Ubuntu version." >&2
  fi
fi

echo "[6/6] Done"
