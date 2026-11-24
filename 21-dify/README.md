# 21-dify

Dify、plugin daemon、agent backend、sandbox、PostgreSQL、RustFS、Valkey、Qdrant、nginx、内部PyPIをまとめたworkflow stack。

Dify 1.20.0のapplication storageにはS3 backendを指定し、S3互換endpointとしてRustFSを使用する。Difyが発行するpresigned URLをbrowserからも開けるように、`PUBLIC_HOST`はDify containerと利用者端末の両方から到達できるhost名またはIP addressにしなければならない（MUST）。

PostgreSQLは`18.7-alpine3.24`、Valkeyは`9.2.0-alpine3.24`へ固定する。Dify 1.20.0公式ComposeのPostgreSQL 15およびRedis 6より新しいmajorを使用するため、本stackではAPI、worker、plugin daemon、queue、cacheを統合testしなければならない（MUST）。

ValkeyはRedis protocolとの互換性を維持しているため、Dify、Celery、plugin daemon、agent backendの接続設定では`REDIS_*`環境変数と`redis://`schemeをそのまま使用する。

productionでは`.env`の`DIFY_DB_USER`、`DIFY_DB_PASSWORD`、`DIFY_RUSTFS_ACCESS_KEY`、`DIFY_RUSTFS_SECRET_KEY`を変更し、既定値を使用してはならない（MUST NOT）。

## 起動時初期化

このstackには複数の依存付き初期化処理がある。

| Service | 初期化内容 |
| --- | --- |
| `dify-rustfs-bucket-init` | Compose内のinit commandでRustFSに`dify-bucket`が無ければ作成する。 |
| `dify-api` | `MIGRATION_ENABLED=true`によりDify本体DB migrationを実行する。 |
| `dify-postgres-init` | Compose内のinit commandでplugin daemon用の`dify_plugin` databaseを存在しなければ作成する。 |
| `dify-plugin-daemon` | `dify-postgres-init`完了後にplugin storageとplugin APIを起動する。 |
| `dify-nginx` | API、Web、plugin daemonがhealthyになってから公開endpointを起動する。 |

Difyの認証はDify自身のemail/password認証に限定する。管理者userはDifyの初回セットアップ画面で作成する。

Marketplace、update確認、website reader、sandbox network、public DNSは無効化する。plugin daemonは`pypiserver`だけをPython package indexとして使用する。air-gap向けの資材取得、plugin導入、egress境界、検証は[docs/manual/DIFY_AIRGAP.md](../docs/manual/DIFY_AIRGAP.md)に従う。

## 起動

```bash
# Dify stackを起動する。
sudo docker compose --env-file .env --profile dify up -d
```

期待結果:

- `dify-rustfs-bucket-init`と`dify-postgres-init`が正常終了する。
- `dify-postgres`がPostgreSQL 18.7でhealthyになる。
- `dify-api`、`dify-worker`、`dify-web`、`dify-plugin-daemon`がhealthyになる。
- `pypiserver`がhealthyになり、plugin daemonから内部wheelを取得できる。
- `dify-rustfs`とValkey 9.2.0の`dify-valkey`がhealthyになる。
- `dify-nginx`が`http://${PUBLIC_HOST}:32100`で応答する。

失敗条件:

- RustFSのcredential不一致または`dify-bucket`作成失敗によりDify APIが起動しない。
- `dify_plugin` databaseの作成に失敗する。
- Valkey passwordやplugin daemon keyの不一致でservice間通信が失敗する。
- `dify-agent-backend`または`dify-local-sandbox`が起動せず、agent系機能が使えない。

## 確認手順

```bash
# Dify profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile dify ps

# Dify公開endpointの応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32100" >/dev/null

# plugin daemonのhealth endpointを確認する。
sudo docker compose --env-file .env --profile dify exec dify-plugin-daemon curl -fsS http://127.0.0.1:5002/health/check >/dev/null

# RustFSのS3 APIでDify bucketを確認する。
sudo docker compose --env-file .env --profile dify run --rm --entrypoint aws dify-rustfs-bucket-init s3api head-bucket --bucket dify-bucket

# ValkeyへDifyと同じpasswordで接続できることを確認する。
sudo docker compose --env-file .env --profile dify exec dify-valkey valkey-cli -a dify_redis_password ping

# PostgreSQLとValkeyの実行versionを確認する。
sudo docker compose --env-file .env --profile dify exec dify-postgres psql -U "${DIFY_DB_USER:-dify_user}" -d dify_db -Atc 'SHOW server_version;'
sudo docker compose --env-file .env --profile dify exec dify-valkey valkey-cli -a dify_redis_password INFO server
```

期待結果:

- `dify-rustfs-bucket-init`と`dify-postgres-init`が`exited (0)`になる。
- Difyの初回セットアップ画面またはlogin画面が表示される。
- plugin daemon healthcheckが成功する。
- RustFSのbucket確認が成功し、Valkeyが`PONG`を返す。
- PostgreSQLが`18.7`、Valkeyが`9.2.0`を報告する。

失敗条件:

- `dify-api` logにmigration失敗が出る。
- `dify-plugin-daemon` logにdatabase接続失敗が出る。
- `dify-nginx`がupstreamへ接続できない。
- Dify containerから`http://${PUBLIC_HOST}:32102`へ到達できず、S3接続に失敗する。

## 既存環境からの移行

PostgreSQL 15、旧file storage、Redis 8からの移行は、[Dify migration manual](../docs/manual/migration/DIFY.md)を正本とする。

## 再初期化

Difyを完全に初期化し直す場合は、Dify関連volumeを削除する。既存workflow、user、plugin、vector dataを失う。

```bash
# Dify stackを停止する。
sudo docker compose --env-file .env --profile dify down

# Dify関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_dify-plugin-daemon" "${STACK_NAME}_dify-postgres-18-data" "${STACK_NAME}_dify-rustfs-data" "${STACK_NAME}_dify-valkey-data" "${STACK_NAME}_dify-qdrant-storage" "${STACK_NAME}_dify-qdrant-snapshots"

# Dify stackを再作成する。
sudo docker compose --env-file .env --profile dify up -d
```

期待結果:

- Difyの初回セットアップが再表示される。
- permission初期化とdatabase初期化が再実行される。

失敗条件:

- volumeが使用中で削除できない。
- 初回セットアップ後もworkerがhealthyにならない。

## References

- [Dify 1.16.1 S3 storage configuration](https://github.com/langgenius/dify/blob/1.16.1/api/configs/middleware/storage/amazon_s3_storage_config.py)
- [Dify 1.16.1 AWS S3 storage implementation](https://github.com/langgenius/dify/blob/1.16.1/api/extensions/storage/aws_s3_storage.py)
- [Dify 1.16.1 official Docker Compose](https://github.com/langgenius/dify/blob/1.16.1/docker/docker-compose.yaml)
- [PostgreSQL 18 major-version upgrade](https://www.postgresql.org/docs/18/upgrading.html)
- [PostgreSQL official image PGDATA changes](https://hub.docker.com/_/postgres)
- [RustFS SDK overview and S3 compatibility](https://docs.rustfs.com/en/developer/sdk)
- [Valkey compatibility and Redis migration](https://valkey.io/topics/migration/)
