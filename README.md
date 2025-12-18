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

補足:

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

## Zabbix だけ作り直す

Cloudflare Access 用の Zabbix ドメインを変更したい（例: `zabbix.ops.example.com` のような2階層を避ける）場合など、
Zabbix だけを再生成できます。

```bash
bash scripts/zabbix-recreate.sh --config config/config.yml --out out
```

1) 設定を用意

注意:
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


4) （任意）Cloudflare DNS を自動設定

DNSが未設定だと、ブラウザから到達できません。
このリポジトリは Cloudflare API を使って `edge.sites[*].tls_domains` の A/AAAA レコードを作成/更新できます。

事前準備:
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
  - `bash scripts/init-secrets.sh` 実行後は `out/.env` も自動生成されます。
  - もし `out/.env` が無い場合は `docker compose --env-file ./secrets.env up -d` を使ってください。

7) WordPress 初期化（マルチサイト化）

```bash
bash scripts/wp-bootstrap.sh
```

補足:

```bash
WP_CLI_MEMORY_LIMIT=1024M bash scripts/wp-bootstrap.sh
```

更新（証明書更新）:

```bash
bash scripts/certbot.sh renew --config config/config.yml --out out --reload-edge
# （念のため明示 reload したい場合）
docker compose -f out/docker-compose.yml --env-file out/secrets.env exec edge nginx -s reload
```

Cloudflare の 526（Full strict）対策メモ:
- オリジン証明書を更新/再発行したら、`edge` の Nginx reload が必要です（更新ファイルを読み直すため）。
- ドメインを追加/変更して証明書の SAN を更新したい場合は強制再発行します。

```bash
bash scripts/certbot.sh issue --config config/config.yml --out out --force --reload-edge
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
## アップロード上限（最大 512MB）

アップロード上限は `config/config.yml` の以下で調整します。
- `wordpress.php.upload_max_mb`（最大 512）
- `wordpress.php.post_max_mb`（upload以上）
- `wordpress.php.memory_limit_mb`

注意:
- Cloudflare のプロキシ（オレンジ雲）経由だと、Cloudflare 側のアップロード上限に先に当たる場合があります。
