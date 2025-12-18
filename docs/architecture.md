# WordPress + Zabbix（同一ホスト）Docker構成 設計メモ

作成日: 2025-12-18

## 1. いまの理解（要件の解釈）

### 対象OS（最小インストール）
- Ubuntu 25.04
- Amazon Linux 2023

### ホスト（SYSTEM）に必ず適用
- Timezone: `Asia/Tokyo`
- システム言語: 英語（例: `en_US.UTF-8`）
- NTP: `ntp.nict.jp` を参照すること

### 外部公開ポリシー
- 外部からの接続は **443のみ**（HTTPSのみ）
- Cloudflare を **プロキシ（オレンジクラウド）** として利用したい
- Zabbix は Cloudflare Access でアクセス制限（ただし **別ドメイン・別証明書** で外部公開）

### WordPress
- 「一度のインストールで複数サブドメイン」= **WordPress Multisite（サブドメイン方式）** を想定
- ドメインは2系統（例）
  - A: `example.com` 配下（`wp-01.example.com`, `wp-02.example.com` などを1つのWPネットワークに収容）
  - B: `example.me` 配下（同様）

### Docker コンポーネント要件
- Nginx
- PHP（最新 8.5 系を想定）
  - php-fpm / curl / dom / exif / fileinfo / hash / json / mbstring / mysql / sodium / openssl / pcre / imagick / xml / zip
  - アップロード上限: **256MB**
- MariaDB
- certbot + `certbot-dns-cloudflare`
  - Let’s Encrypt **Wildcard** が導入可能（DNS-01）
  - 既に同一FQDNの証明書がある場合は再利用
  - 作成された証明書は Docker からマウントできるように `ln` で揃える

### Zabbix
- Zabbix Server
- Zabbix Agent

> 注: 「Zabbix Agent」をホストに入れるかコンテナに入れるかは設計選択だが、要件上は“導入されていること”が重要。

---

## 2. 全体像（ホスト導入 vs Docker導入の切り分け）

### ホスト側に導入するもの（OSパッケージ）
- TZ/Locale/NTP 設定
- Docker Engine / Docker Compose（plugin）
- （推奨）Zabbix Agent: ホスト監視のためホストに入れる
  - 監視先（Zabbix Server）は同一ホスト上のコンテナ（内部ネットワーク）

### Docker（compose）に載せるもの
- 入口（Edge）Nginx: **ホストの443を唯一Listen**（SNIで振り分け）
- Stack A（example.com）: Nginx（内部） + PHP-FPM + WordPress + MariaDB
- Stack B（example.me）: Nginx（内部） + PHP-FPM + WordPress + MariaDB
- Zabbix: zabbix-server + zabbix-web + zabbix-db（MariaDB/PostgreSQLどちらでも。ここでは要件の「MariaDB」とは分離してもよい）
- certbot: DNS-01で証明書更新（`certbot-dns-cloudflare`）

---

## 3. コンテナ関係図（Mermaid）

### 3.1 ネットワーク境界と443集約（SNI）

```mermaid
flowchart TB
  Internet((Internet)) --> CF[Cloudflare Proxy
Orange Cloud]
  CF -->|HTTPS 443| Host443[Host:443
(edge)
Nginx Reverse Proxy]

  subgraph HOST[Single Host: Ubuntu/AL2023]
    Host443 -->|SNI: example.com / *.example.com| WP_A_EDGE
    Host443 -->|SNI: example.me / *.example.me| WP_B_EDGE
    Host443 -->|SNI: zabbix.<domain>| ZBX_EDGE

    subgraph DOCKER[Docker / Compose]
      direction TB

      subgraph NET_PUBLIC[net_public (bridge)]
        Host443
      end

      subgraph NET_A[net_wp_a]
        WP_A_EDGE[Nginx (wp-a) internal]
        PHP_A[php-fpm (8.5) wp-a]
        WP_A[WordPress wp-a
(multisite: subdomain)]
        DB_A[(MariaDB wp-a)]
        WP_A_EDGE --> PHP_A
        PHP_A --> WP_A
        WP_A --> DB_A
      end

      subgraph NET_B[net_wp_b]
        WP_B_EDGE[Nginx (wp-b) internal]
        PHP_B[php-fpm (8.5) wp-b]
        WP_B[WordPress wp-b
(multisite: subdomain)]
        DB_B[(MariaDB wp-b)]
        WP_B_EDGE --> PHP_B
        PHP_B --> WP_B
        WP_B --> DB_B
      end

      subgraph NET_ZBX[net_zabbix]
        ZBX_EDGE[Nginx (zbx) internal]
        ZBX_WEB[zabbix-web]
        ZBX_SRV[zabbix-server]
        ZBX_DB[(zabbix-db)]
        ZBX_EDGE --> ZBX_WEB
        ZBX_WEB --> ZBX_SRV
        ZBX_SRV --> ZBX_DB
      end

      CERTBOT[certbot
+ dns-cloudflare]
    end

    ZBX_AGENT[Zabbix Agent
(host package)]
    ZBX_AGENT -->|active/passive| ZBX_SRV
  end
```

ポイント:
- **外部へ公開するのは edge の443のみ**（stack内のNginxやDBはポート公開しない）
- Cloudflareはプロキシとして前段にいる
- Zabbixは `zabbix.<domain>` の **別証明書** を edge が提示し、Cloudflare Access をそのFQDNに適用

### 3.2 証明書（DNS-01）とマウント/ln

```mermaid
flowchart LR
  CFAPI[Cloudflare API Token
(DNS Edit)] --> CERT[certbot-dns-cloudflare]
  CERT --> LE[(Let's Encrypt)]
  CERT -->|/etc/letsencrypt/live/...| CERTDIR[/Host cert dir/]
  CERTDIR -->|bind mount| EDGE[edge Nginx container]

  note1["既存証明書があれば再利用\n(すでに /etc/letsencrypt/live/<name> がある等)" ]
  CERTDIR --- note1
```

想定運用:
- certbot はホストの永続ディレクトリ（固定: **`/srv/letsencrypt`**）を使う
- `scripts/link-certs.sh` により `/etc/letsencrypt` は `ln` で `/srv/letsencrypt` に寄せる（要件）

---

## 4. Cloudflare（プロキシ/Access）を入れるときの注意点

### 4.1 SSL/TLS モード
- Cloudflare SSL/TLS は **Full (strict)** を前提にする
  - オリジン（このホスト）側の edge は有効な証明書（Let’s Encrypt Wildcard等）を提示
  - `Flexible` は非推奨（オリジンがHTTPになりがち）

### 4.2 実クライアントIP
- オリジンから見る送信元は Cloudflare のIPになりやすい
- edge で `CF-Connecting-IP` / `X-Forwarded-For` を信頼して実IP復元する
- “信頼するプロキシ”は Cloudflare の送信元IPレンジのみに限定する（ヘッダ偽装対策）

### 4.3 Access の迂回対策
- Cloudflare Access は Cloudflare 経由トラフィックに適用される
- オリジンを直接叩かれると迂回され得るため、可能なら
  - ホストFWで **443の受信元をCloudflare IPレンジに限定**（少なくともZabbixは必須）

---

## 5. 実装方針（どう作っていくか）

### 5.1 ゴール
- 1台ホストで、以下が自動構築できる
  - OS初期設定（TZ/Locale/NTP）
  - Docker/Compose導入
  - `docker compose up -d` で WP-A / WP-B / Zabbix / certbot / edge が起動
  - Let’s Encrypt WildcardをDNS-01で取得/更新（既存があれば再利用）
  - PHPアップロード上限 256MB
  - ドメインやFQDNは **設定ファイルで差し替え可能**

### 5.2 実装の分割（レポジトリ内成果物のイメージ）
- `config/config.yml`（ユーザー編集する設定ファイル）
- `scripts/`
  - `setup-ubuntu.sh` / `setup-al2023.sh`（OS初期設定 + Docker導入）
  - `render-compose.py` もしくは `render-compose.sh`（設定ファイルからcompose/vhost生成）
  - `up.sh` / `down.sh`
  - `cert/issue.sh`（初回発行）
  - `cert/renew.sh`（更新＋edge reload）
- `stacks/`
  - `compose.yml`（生成物 or テンプレ）
  - `nginx/edge/*.conf`（生成物 or テンプレ）
  - `php/php.ini`（upload 256MB 反映）

> 生成方式は2案
> - A) **テンプレ+変数置換（envsubst等）**: 依存が少ない
> - B) **YAMLを読み込み生成（Python等）**: 柔軟だがPython依存が増える

---

## 6. 設定ファイル（案）

### 6.1 形式
- 推奨: YAML（読みやすく階層化しやすい）
- 秘密情報（Cloudflare Token / DBパスワード等）は `config/secrets.env` のように別ファイルで管理（Git除外）

### 6.2 キー案（最小）

```yaml
system:
  timezone: Asia/Tokyo
  locale: en_US.UTF-8
  ntp_servers:
    - ntp.nict.jp

cloudflare:
  proxy_enabled: true
  dns_api_token_env: CF_DNS_API_TOKEN

edge:
  bind_host: 0.0.0.0
  bind_port: 443
  tls:
    email: admin@example.com
    reuse_existing: true
    letsencrypt_dir: /etc/letsencrypt

stacks:
  - name: wp-a
    apex_domain: example.com
    tls_domains:
      - example.com
      - "*.example.com"
    wordpress:
      multisite:
        enabled: true
        mode: subdomain
      php:
        upload_max_mb: 256
      db:
        root_password_env: WP_A_DB_ROOT_PASSWORD
        database: wordpress
        user: wordpress
        password_env: WP_A_DB_PASSWORD

  - name: wp-b
    apex_domain: example.me
    tls_domains:
      - example.me
      - "*.example.me"
    wordpress:
      multisite:
        enabled: true
        mode: subdomain
      php:
        upload_max_mb: 256
      db:
        root_password_env: WP_B_DB_ROOT_PASSWORD
        database: wordpress
        user: wordpress
        password_env: WP_B_DB_PASSWORD

zabbix:
  enabled: true
  public_domain: zabbix.ops.example.net
  tls_domains:
    - zabbix.ops.example.net
  cloudflare_access:
    enabled: true

firewall:
  inbound_443: cloudflare_only
```

---

## 7. 実装時に確定させる判断（ここは作りながら固定する）

- edge は Nginx で固定するか（本メモは Nginx 想定）
- Zabbix のDBは **PostgreSQL** を使用する（決定）
- Zabbix Agent をホスト導入にするか、コンテナにするか（ホスト監視目的ならホスト導入が自然）
- “443のみ”をどこまで強制するか
  - 受信元を Cloudflare IPレンジに限定するか（Zabbixは強く推奨）

---

## 8. 次に作るもの（このリポジトリでの成果物）

- `docs/architecture.md`（このファイル）
- `config/config.yml` の雛形（`.example`）
- OS別セットアップスクリプト（Ubuntu/AL2023）
- `docker-compose.yml` と Nginx vhost（SNI）
- certbot DNS-01（cloudflare）での発行/更新スクリプト

