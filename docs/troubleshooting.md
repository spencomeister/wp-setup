# トラブルシューティング

## `pull access denied for wpcli/wp-cli`

原因:
- `wpcli/wp-cli` は取得できない（リポジトリ名が存在しない/変更された）ため、`docker compose up` 時に pull が失敗します。

対処:
1. リポジトリを最新化（この修正を含む版）
2. `out/` を再生成

```bash
python3 scripts/render.py --config config/config.yml --out out
```

3. 再度起動

```bash
docker compose -f out/docker-compose.yml --env-file out/secrets.env up -d
```

確認:
- `docker images | grep wordpress` で `wordpress:cli` が pull されていること

---

## edge が Restarting（`duplicate "log_format" name "main"`）

症状:
- `docker logs wp-setup-edge-1` に以下が出て再起動ループ
	- `duplicate "log_format" name "main" in /etc/nginx/conf.d/00-edge.conf`

原因:
- `nginx:stable` イメージ側で既に `log_format main` が定義されているのに、こちらの設定でも同名を定義していた

対処:
1) `out/` を再生成

```bash
python3 scripts/render.py --config config/config.yml --out out
```

2) edge を再起動

```bash
docker compose -f out/docker-compose.yml --env-file out/secrets.env up -d
docker compose -f out/docker-compose.yml --env-file out/secrets.env restart edge
```

次に出やすいエラー:
- `/srv/letsencrypt/live/...` が無い（証明書未発行）→ 下の「証明書が無い」へ

---

## `config.yml` にトークンや secrets を貼り付けて壊した

よくある症状:
- `config/config.yml` の `cloudflare.dns_api_token_env` に「トークン本体」を入れてしまう
- `config/config.yml` に `secrets.env` の内容を貼り付けて YAML が壊れる（重複キー/不正インデント）

正:
- `cloudflare.dns_api_token_env` は **環境変数名**（例: `CF_DNS_API_TOKEN`）
- トークン本体は `out/secrets.env`（または元ネタの `config/secrets.env`）に `CF_DNS_API_TOKEN=...` として入れる

復旧:
- `config/config.yml.example` をベースに `config/config.yml` を作り直し
- `bash scripts/init-secrets.sh` で `out/secrets.env` を作り直し

---

## `certbot.sh` で `out/certbot includes invalid characters for a local volume name`

原因:
- `bash scripts/certbot.sh ... --out out` のように `--out` に相対パスを渡すと、Dockerが `out/certbot` をホストパスではなく "ボリューム名" として解釈して失敗することがあります。

対処:
- 修正版ではスクリプト側で絶対パスに正規化します。
- もし古い版を使っている場合は、`--out` を絶対パスで渡してください（例: `--out /root/wp-setup/out`）。

---

## `docker compose ps` で `The "XXX" variable is not set. Defaulting to a blank string.`

原因:
- `docker-compose.yml` 内の `${WP_A_DB_PASSWORD}` のような **compose側の変数展開**は、`env_file:` では解決されません。
	- これは「コンテナに渡す環境変数」と「composeがYAMLを解釈する時の変数」が別物のためです。

対処（どちらか）:
1) README通りに `--env-file` を付けて実行する

```bash
docker compose -f out/docker-compose.yml --env-file out/secrets.env up -d
docker compose -f out/docker-compose.yml --env-file out/secrets.env ps
```

2) `out/.env` を用意してから `cd out` で実行する
- `bash scripts/init-secrets.sh` を実行すると `out/.env` も自動生成されます。

---

## `wp-bootstrap.sh` 実行時に `Allowed memory size ... exhausted`（wp-cliのPHP OOM）

原因:
- `wordpress:cli` 内の PHP `memory_limit` が小さく、WordPressの展開処理でメモリ不足になります（128MBで発生しやすい）。

対処:
- 修正版では `WP_CLI_PHP_ARGS='-d memory_limit=512M'` を付与して実行します。
- 反映後、`out/` を再生成してから再実行してください。

