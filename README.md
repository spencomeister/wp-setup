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

※ `templates/` を更新した場合は、必ず `scripts/render.py` を再実行して `out/` を作り直してください。

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

## 一気通貫（推奨）

`config/config.yml` と `config/secrets.env` が記入済みなら、以下で通し実行できます。

```bash
# 破棄（DB/WPデータ削除）
bash scripts/run.sh --scrap

# 作成（render → secrets → Cloudflare DNS(有効時) → certbot → compose up → wp-bootstrap）
bash scripts/run.sh --create

# 破棄して作り直し
bash scripts/run.sh --scrap-and-recreate
```

1) 設定を用意
- `config/config.yml` を作成
- `config/secrets.env` を作成（最低限 `CF_DNS_API_TOKEN=` を埋める）

注意:
- `config/config.yml` の `letsencrypt.email` は **実在するメールアドレス**にしてください（`admin@example.com` のままだと Let’s Encrypt に拒否されます）
- WordPress を2スタックに分ける場合、基本は **別の apex ドメイン（例: `example.com` と `example.me`）** を推奨します。
  - もし2つ目を `stg.example.com` のように「1つ目の配下サブドメイン」を apex にする場合、
    - edge の振り分けが `*.example.com` に吸われやすい（設定ミスで wp-a 側に入る）
    - Multisite（subdomain）なら `*.stg.example.com` のDNS/証明書が必要
    になります。

2) 生成
```bash
python3 scripts/render.py --config config/config.yml --out out
```

3) シークレット自動生成（DB/管理者パスワード）

```bash
bash scripts/init-secrets.sh
```

- 出力: `config/secrets.env`（永続） + `out/secrets.env`（存在すればコピー）
- ログ: `logs/secrets-<timestamp>.log`（要求通り **パスワードが残ります**）

4) （任意）Cloudflare DNS を自動設定

DNSが未設定だと、ブラウザから到達できません。
このリポジトリは Cloudflare API を使って `edge.sites[*].tls_domains` の A/AAAA レコードを作成/更新できます。

事前準備:
- `config/config.yml` で `cloudflare.dns.enabled: true` を設定
  - `cloudflare.dns.origin_ipv4` は未指定（または `auto`）なら **自動取得**します
  - `origin_ipv6` も `auto` で自動取得できます（未指定でもOK）

実行（まず plan 推奨）:

```bash
bash scripts/cloudflare-dns.sh plan  --config config/config.yml
bash scripts/cloudflare-dns.sh apply --config config/config.yml
```

5) 証明書発行（既存があれば再利用）

```bash
bash scripts/link-certs.sh
bash scripts/certbot.sh issue --config config/config.yml --out out
```

6) コンテナ起動

```bash
docker compose -f out/docker-compose.yml --env-file out/secrets.env up -d
```

補足:
- `cd out` して `docker compose up -d` のように実行する場合、compose の変数展開用に `out/.env` が必要です。
  - `bash scripts/init-secrets.sh` 実行後は `out/.env` も自動生成されます。
  - もし `out/.env` が無い場合は `docker compose --env-file ./secrets.env up -d` を使ってください。

7) WordPress 初期化（マルチサイト化）

```bash
bash scripts/wp-bootstrap.sh
```

補足:
- もし `wp-bootstrap.sh` が `Allowed memory size ... exhausted` で落ちる場合は、wp-cli 側のメモリ上限を上げて再実行できます。

```bash
WP_CLI_MEMORY_LIMIT=1024M bash scripts/wp-bootstrap.sh
```

更新（証明書更新）:

```bash
bash scripts/certbot.sh renew --config config/config.yml --out out
docker compose -f out/docker-compose.yml --env-file out/secrets.env exec edge nginx -s reload
```

## 最初からやり直す（DB/WPデータ削除）

注意: `down -v` により MariaDB/PostgreSQL/WordPress のデータが消えます（証明書は消しません）。

```bash
cd ~/wp-setup/out
docker compose down -v --remove-orphans

cd ~/wp-setup
# （必要なら）既存の秘密情報を作り直したい場合のみ
# rm -f config/secrets.env

bash scripts/init-secrets.sh
python3 scripts/render.py --config config/config.yml --out out

docker compose -f out/docker-compose.yml --env-file out/secrets.env up -d
bash scripts/wp-bootstrap.sh
```

## メモ
- Cloudflare をオレンジクラウド運用する場合、Cloudflare 側は `Full (strict)` 推奨
- “443のみ” を厳密にするなら、ホストFWで 443 受信元を Cloudflare IPレンジに限定する方針が安全
