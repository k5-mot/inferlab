# 21-dify

Dify、plugin daemon、agent backend、sandbox、PostgreSQL、RustFS、Valkey、Qdrant、nginxをまとめたworkflow stack。

Dify 1.16.1のapplication storageにはS3 backendを指定し、S3互換endpointとしてRustFSを使用する。Difyが発行するpresigned URLをbrowserからも開けるように、`PUBLIC_HOST`はDify containerと利用者端末の両方から到達できるhost名またはIP addressにしなければならない（MUST）。

ValkeyはRedis protocolとの互換性を維持しているため、Dify、Celery、plugin daemon、agent backendの接続設定では`REDIS_*`環境変数と`redis://`schemeをそのまま使用する。

productionでは`.env`の`DIFY_RUSTFS_ACCESS_KEY`と`DIFY_RUSTFS_SECRET_KEY`を変更し、既定値を使用してはならない（MUST NOT）。

## 起動時初期化

このstackには複数の依存付き初期化処理がある。

| Service | 初期化内容 |
| --- | --- |
| `dify-rustfs-bucket-init` | Compose内のinit commandでRustFSに`dify-bucket`が無ければ作成する。 |
| `dify-api` | `MIGRATION_ENABLED=true`によりDify本体DB migrationを実行する。 |
| `dify-postgres-init` | Compose内のinit commandでplugin daemon用の`dify_plugin` databaseを存在しなければ作成する。 |
| `dify-plugin-daemon` | `dify-postgres-init`完了後にplugin storageとplugin APIを起動する。 |
| `dify-nginx` | API、Web、plugin daemonがhealthyになってから公開endpointを起動する。 |

Dify OSS版は、このComposeだけでは汎用OIDC/Keycloak SSOを有効化しない。管理者userはDifyの初回セットアップ画面で作成する。

## 起動

```bash
# Dify stackを起動する。
sudo docker compose --env-file .env --profile dify up -d
```

期待結果:

- `dify-rustfs-bucket-init`と`dify-postgres-init`が正常終了する。
- `dify-api`、`dify-worker`、`dify-web`、`dify-plugin-daemon`がhealthyになる。
- `dify-rustfs`と`dify-valkey`がhealthyになる。
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
```

期待結果:

- `dify-rustfs-bucket-init`と`dify-postgres-init`が`exited (0)`になる。
- Difyの初回セットアップ画面またはlogin画面が表示される。
- plugin daemon healthcheckが成功する。
- RustFSのbucket確認が成功し、Valkeyが`PONG`を返す。

失敗条件:

- `dify-api` logにmigration失敗が出る。
- `dify-plugin-daemon` logにdatabase接続失敗が出る。
- `dify-nginx`がupstreamへ接続できない。
- Dify containerから`http://${PUBLIC_HOST}:32102`へ到達できず、S3接続に失敗する。

## 既存環境からの移行

変更前の構成はMinIOではなく`dify-storage` volumeを使用していた。Compose更新だけでは既存fileをRustFSへ移行しないため、既存環境ではDify停止中に旧volumeの内容を`dify-bucket`へ同期しなければならない（MUST）。PostgreSQLとQdrantのvolumeは継続利用する。

Redis 8のRDB fileをValkey 8へ直接読み込む方式は採用しない。新しい`dify-valkey-data` volumeを使用するため、切替時点のcache、session、未完了Celery taskは引き継がれない。切替前に実行中workflowが無いことを確認しなければならない（MUST）。

rollbackする場合は旧Compose revisionへ戻し、削除せずに残した`dify-storage`と`dify-redis-data` volumeを再利用する。RustFS切替後に作成または更新したfileとValkey上の状態は旧volumeへ自動反映されない。

## 再初期化

Difyを完全に初期化し直す場合は、Dify関連volumeを削除する。既存workflow、user、plugin、vector dataを失う。

```bash
# Dify stackを停止する。
sudo docker compose --env-file .env --profile dify down

# Dify関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_dify-plugin-daemon" "${STACK_NAME}_dify-postgres-data" "${STACK_NAME}_dify-rustfs-data" "${STACK_NAME}_dify-valkey-data" "${STACK_NAME}_dify-qdrant-storage" "${STACK_NAME}_dify-qdrant-snapshots"

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
- [RustFS SDK overview and S3 compatibility](https://docs.rustfs.com/en/developer/sdk)
- [Valkey compatibility and Redis migration](https://valkey.io/topics/migration/)
