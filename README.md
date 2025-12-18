# wp-setup

最小インストールの Linux（Ubuntu 25.04 / Amazon Linux 2023）に対して、
1台ホスト上で Docker を用い、以下をまとめて構築するためのひな形です。

- WordPress（ドメインA: `example.com` / ドメインB: `example.me`）
  - 各ドメインで WordPress Multisite（サブドメイン方式）を想定
  - Nginx + PHP-FPM(8.5) + MariaDB
  - PHP upload 上限 256MB
- Zabbix（別ドメイン・別証明書で公開）
  - DB は PostgreSQL（決定）
  - Cloudflare Access は Zabbix のみ
- Let’s Encrypt（DNS-01 / `certbot-dns-cloudflare`）
  - Wildcard 証明書
  - 既存証明書があれば再利用

詳細設計は `docs/architecture.md` を参照。

## 使い方（このリポジトリで準備するもの）

### 1) 設定ファイル
- `config/config.yml.example` → `config/config.yml` にコピーして編集
- `config/secrets.env.example` → `config/secrets.env` にコピーして編集（Git管理しない）

補足:
- WordPress のDBパスワードや管理者パスワードは **指定不要**（後述スクリプトで自動生成）
- 必須で入れるのは `CF_DNS_API_TOKEN`（Cloudflare DNS-01用）と、ドメイン/メール等

### 2) 生成（ローカルでOK / ホストでOK）

```pwsh
Set-Location b:\develop\wp-setup
B:/develop/wp-setup/.venv/Scripts/python.exe scripts/render.py --config config/config.yml --out out
```

生成物は `out/` に出ます（`docker-compose.yml` と Nginx/ PHP 設定）。

### 3) ホスト側（Ubuntu/AL2023）準備

Ubuntu:
```bash
sudo bash scripts/setup-ubuntu.sh
```

Amazon Linux 2023:
```bash
sudo bash scripts/setup-al2023.sh
```

## 証明書（DNS-01 / Cloudflare）について

このリポジトリは「証明書発行/更新の置き場」までを想定しています。
- Cloudflare API Token は `config/secrets.env` の `CF_DNS_API_TOKEN` で渡す
- Let’s Encrypt の格納パスは `config/config.yml` の `letsencrypt.dir`（既定: `/etc/letsencrypt`）

## 実行順（ホスト上で）

1) 設定を用意
- `config/config.yml` を作成
- `config/secrets.env` を作成（最低限 `CF_DNS_API_TOKEN=` を埋める）

2) 生成
```bash
python3 scripts/render.py --config config/config.yml --out out
```

3) シークレット自動生成（DB/管理者パスワード）

```bash
bash scripts/init-secrets.sh
```

- 出力: `out/secrets.env`
- ログ: `logs/secrets-<timestamp>.log`（要求通り **パスワードが残ります**）

4) 証明書発行（既存があれば再利用）

```bash
bash scripts/link-certs.sh
bash scripts/certbot.sh issue --config config/config.yml --out out
```

5) コンテナ起動

```bash
docker compose -f out/docker-compose.yml --env-file out/secrets.env up -d
```

6) WordPress 初期化（マルチサイト化）

```bash
bash scripts/wp-bootstrap.sh
```

更新（証明書更新）:

```bash
bash scripts/certbot.sh renew --config config/config.yml --out out
docker compose -f out/docker-compose.yml --env-file out/secrets.env exec edge nginx -s reload
```

## メモ
- Cloudflare をオレンジクラウド運用する場合、Cloudflare 側は `Full (strict)` 推奨
- “443のみ” を厳密にするなら、ホストFWで 443 受信元を Cloudflare IPレンジに限定する方針が安全
