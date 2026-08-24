# 21-dify

Dify、plugin daemon、agent backend、sandbox、PostgreSQL、RustFS、Valkey、Qdrant、nginx、内部PyPIをまとめたworkflow stack。

Dify 1.16.1のapplication storageにはS3 backendを指定し、S3互換endpointとしてRustFSを使用する。Difyが発行するpresigned URLをbrowserからも開けるように、`PUBLIC_HOST`はDify containerと利用者端末の両方から到達できるhost名またはIP addressにしなければならない（MUST）。

PostgreSQLは`18.6-trixie`、Valkeyは`9.1.1-alpine3.24`へ固定する。Dify 1.16.1公式ComposeのPostgreSQL 15およびRedis 6より新しいmajorを使用するため、本stackではAPI、worker、plugin daemon、queue、cacheを統合testしなければならない（MUST）。

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
- `dify-postgres`がPostgreSQL 18.6でhealthyになる。
- `dify-api`、`dify-worker`、`dify-web`、`dify-plugin-daemon`がhealthyになる。
- `pypiserver`がhealthyになり、plugin daemonから内部wheelを取得できる。
- `dify-rustfs`とValkey 9.1.1の`dify-valkey`がhealthyになる。
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
- PostgreSQLが`18.6`、Valkeyが`9.1.1`を報告する。

失敗条件:

- `dify-api` logにmigration失敗が出る。
- `dify-plugin-daemon` logにdatabase接続失敗が出る。
- `dify-nginx`がupstreamへ接続できない。
- Dify containerから`http://${PUBLIC_HOST}:32102`へ到達できず、S3接続に失敗する。

## 既存環境からの移行

### PostgreSQL 15から18

PostgreSQL major間ではdata directoryを直接再利用できない。旧`dify-postgres-data` volumeを保持したまま、PostgreSQL 18 clientによる論理backupを新しい`dify-postgres-18-data` volumeへrestoreしなければならない（MUST）。次の手順ではbackup用volumeもユーザーテスト完了まで保持する。

`DIFY_DB_USER`と`DIFY_DB_PASSWORD`には旧clusterで実際に使用していたcredentialを指定しなければならない（MUST）。初期構成の既定値は`dify_user`と`dify_password`である。

```bash
# 移行対象のCompose project名と旧database credentialを設定する。
export STACK_NAME="${STACK_NAME:-inferlab}"
export DIFY_DB_USER="${DIFY_DB_USER:-dify_user}"
export DIFY_DB_PASSWORD="${DIFY_DB_PASSWORD:-dify_password}"

# Dify stackを停止し、移行中の書込みを止める。
sudo docker compose --env-file .env --profile dify stop

# 旧PostgreSQLだけを隔離して起動する一時networkを作成する。
sudo docker network create "${STACK_NAME}-dify-postgres-upgrade"

# 旧volumeをPostgreSQL 15.19で起動する。
sudo docker run --detach --rm --name "${STACK_NAME}-dify-postgres-15-source" --network "${STACK_NAME}-dify-postgres-upgrade" --env PGDATA=/var/lib/postgresql/data/pgdata --volume "${STACK_NAME}_dify-postgres-data:/var/lib/postgresql/data" docker.io/library/postgres:15.19-alpine

# 論理backupを保存するvolumeを作成する。
sudo docker volume create "${STACK_NAME}_dify-postgres-15-backup"

# PostgreSQL 18 clientでDify本体とplugin databaseをbackupする。
sudo docker run --rm --network "${STACK_NAME}-dify-postgres-upgrade" --env STACK_NAME --env DIFY_DB_USER --env PGPASSWORD="${DIFY_DB_PASSWORD}" --volume "${STACK_NAME}_dify-postgres-15-backup:/backup" docker.io/library/postgres:18.6-trixie sh -euc 'pg_dump -h "${STACK_NAME}-dify-postgres-15-source" -U "${DIFY_DB_USER}" -d dify_db --format=custom --file=/backup/dify_db.dump; pg_dump -h "${STACK_NAME}-dify-postgres-15-source" -U "${DIFY_DB_USER}" -d dify_plugin --format=custom --file=/backup/dify_plugin.dump; pg_restore --list /backup/dify_db.dump >/dev/null; pg_restore --list /backup/dify_plugin.dump >/dev/null'

# 旧PostgreSQLを停止し、一時networkを削除する。
sudo docker stop "${STACK_NAME}-dify-postgres-15-source"
sudo docker network rm "${STACK_NAME}-dify-postgres-upgrade"

# 空のPostgreSQL 18 volumeを初期化してhealthyになるまで待機する。
sudo docker compose --env-file .env --profile dify up -d --wait dify-postgres

# plugin databaseを冪等作成する。
sudo docker compose --env-file .env --profile dify up dify-postgres-init

# Dify本体databaseをPostgreSQL 18へrestoreする。
sudo docker run --rm --network "${STACK_NAME}_internal-nw" --env PGPASSWORD="${DIFY_DB_PASSWORD}" --volume "${STACK_NAME}_dify-postgres-15-backup:/backup:ro" docker.io/library/postgres:18.6-trixie pg_restore -h dify-postgres -U "${DIFY_DB_USER}" -d dify_db --clean --if-exists --no-owner --no-privileges --exit-on-error /backup/dify_db.dump

# plugin databaseをPostgreSQL 18へrestoreする。
sudo docker run --rm --network "${STACK_NAME}_internal-nw" --env PGPASSWORD="${DIFY_DB_PASSWORD}" --volume "${STACK_NAME}_dify-postgres-15-backup:/backup:ro" docker.io/library/postgres:18.6-trixie pg_restore -h dify-postgres -U "${DIFY_DB_USER}" -d dify_plugin --clean --if-exists --no-owner --no-privileges --exit-on-error /backup/dify_plugin.dump

# restore後のdatabaseとtable数を確認する。
sudo docker compose --env-file .env --profile dify exec dify-postgres psql -U "${DIFY_DB_USER}" -d dify_db -Atc "SELECT current_setting('server_version'); SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"

# 全Dify stackを起動する。
sudo docker compose --env-file .env --profile dify up -d
```

期待結果:

- 2つのdumpが`pg_restore --list`で読み取れる。
- PostgreSQL 18の`dify_db`と`dify_plugin`に旧環境と同じschemaおよびdataが存在する。
- 旧`dify-postgres-data`とbackup volumeが削除されずに残る。

失敗条件:

- dump中に旧databaseへ新しい書込みが発生する。
- restoreがschema、extension、constraint、dataのいずれかで失敗する。
- restore前後でaccount、tenant、applicationなどの件数が一致しない。

rollbackする場合は新stackを停止し、旧Compose revisionで`dify-postgres-data`を再度mountする。新PostgreSQLへ切替後の変更は旧volumeへ反映されないため、rollback前に別途論理backupしなければならない（MUST）。

### Storageとcache

変更前の構成はMinIOではなく`dify-storage` volumeを使用していた。Compose更新だけでは既存fileをRustFSへ移行しないため、既存環境ではDify停止中に旧volumeの内容を`dify-bucket`へ同期しなければならない（MUST）。Qdrantのvolumeは継続利用し、PostgreSQLは前節の論理migrationを実施する。

Redis 8のRDB fileをValkey 9へ直接読み込む方式は採用しない。新しい`dify-valkey-data` volumeを使用するため、切替時点のcache、session、未完了Celery taskは引き継がれない。切替前に実行中workflowが無いことを確認しなければならない（MUST）。

rollbackする場合は旧Compose revisionへ戻し、削除せずに残した`dify-storage`と`dify-redis-data` volumeを再利用する。RustFS切替後に作成または更新したfileとValkey上の状態は旧volumeへ自動反映されない。

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
