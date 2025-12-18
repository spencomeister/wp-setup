# scripts

ここに「設定ファイルから生成」「OS初期化」「certbot発行/更新」を置きます。

予定:
- render.py: config/config.yml → out/ 以下に docker-compose.yml と nginx conf を生成
- setup-ubuntu.sh / setup-al2023.sh: TZ/Locale/NTP/Docker/Zabbix Agent をセットアップ
