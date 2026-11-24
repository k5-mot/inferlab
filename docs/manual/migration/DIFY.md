# Difyの永続data移行手順

## 対象

DifyのPostgreSQL 15を18へ論理移行し、旧`dify-storage` volumeをRustFSへ同期する。Redis 8のcacheと未完了Celery taskは移行せず、emptyのValkey 9へ切り替える。Qdrant volumeは継続利用する。

## 事前条件とBackup

実行中workflowとCelery taskを完了または中止し、Difyへの書込みを停止する。例はCompose project名`inferlab`を使用する。

```bash
# Compose project名、旧database credential、backup先を設定する。
export STACK_NAME="${STACK_NAME:-inferlab}"
export DIFY_DB_USER="${DIFY_DB_USER:-dify_user}"
export DIFY_DB_PASSWORD="${DIFY_DB_PASSWORD:-dify_password}"
export DIFY_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export DIFY_BACKUP_DIR="/srv/backup/inferlab/dify/${DIFY_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$DIFY_BACKUP_DIR"

# Dify stackを停止してdatabaseとstorageへの書込みを止める。
sudo docker compose --env-file .env --profile dify stop

# 旧file storageをraw archiveへ保存する。
sudo docker run --rm --network none --read-only --volume "${STACK_NAME}_dify-storage:/source:ro" --volume "$DIFY_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/dify-storage.tar.gz -C /source .'

# 旧PostgreSQL volumeをraw archiveへ保存する。
sudo docker run --rm --network none --read-only --volume "${STACK_NAME}_dify-postgres-data:/source:ro" --volume "$DIFY_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/dify-postgres-15-data.tar.gz -C /source .'

# archiveの読み取りとchecksumを検証する。
sudo tar -tzf "$DIFY_BACKUP_DIR/dify-storage.tar.gz" >/dev/null
sudo tar -tzf "$DIFY_BACKUP_DIR/dify-postgres-15-data.tar.gz" >/dev/null
sudo sha256sum "$DIFY_BACKUP_DIR/dify-storage.tar.gz" "$DIFY_BACKUP_DIR/dify-postgres-15-data.tar.gz" | sudo tee "$DIFY_BACKUP_DIR/SHA256SUMS"
```

期待結果:

- 2つのarchiveを読み取れ、旧volumeが残る。
- backup中にAPI、worker、plugin daemonから書込みが発生しない。

失敗条件:

- 旧volumeが存在しない、空である、またはarchiveを読み取れない。
- 実行中workflowまたはCelery taskが残る。

## PostgreSQL 15から18への移行

PostgreSQL major間でdata directoryを直接再利用してはならない（MUST NOT）。

```bash
# 旧PostgreSQLだけを隔離して起動する一時networkを作成する。
sudo docker network create "${STACK_NAME}-dify-postgres-upgrade"

# 旧volumeをPostgreSQL 15で一時起動する。
sudo docker run --detach --name "${STACK_NAME}-dify-postgres-15-source" --network "${STACK_NAME}-dify-postgres-upgrade" --env PGDATA=/var/lib/postgresql/data/pgdata --volume "${STACK_NAME}_dify-postgres-data:/var/lib/postgresql/data" docker.io/library/postgres:15.19-alpine

# source databaseが接続可能になるまで待機する。
sudo docker exec "${STACK_NAME}-dify-postgres-15-source" sh -euc 'until pg_isready -U "${POSTGRES_USER:-dify_user}" -d dify_db; do sleep 1; done'

# 論理backup用volumeを作成する。
sudo docker volume create "${STACK_NAME}_dify-postgres-15-backup"

# Dify本体とplugin databaseをcustom archiveへdumpする。
sudo docker run --rm --network "${STACK_NAME}-dify-postgres-upgrade" --env STACK_NAME --env DIFY_DB_USER --env PGPASSWORD="$DIFY_DB_PASSWORD" --volume "${STACK_NAME}_dify-postgres-15-backup:/backup" docker.io/library/postgres:18.7-alpine3.24 sh -euc 'pg_dump -h "${STACK_NAME}-dify-postgres-15-source" -U "${DIFY_DB_USER}" -d dify_db --format=custom --file=/backup/dify_db.dump; pg_dump -h "${STACK_NAME}-dify-postgres-15-source" -U "${DIFY_DB_USER}" -d dify_plugin --format=custom --file=/backup/dify_plugin.dump; pg_restore --list /backup/dify_db.dump >/dev/null; pg_restore --list /backup/dify_plugin.dump >/dev/null'

# 旧PostgreSQLを削除し、一時networkを削除する。
sudo docker rm --force "${STACK_NAME}-dify-postgres-15-source"
sudo docker network rm "${STACK_NAME}-dify-postgres-upgrade"

# PostgreSQL 18を新しいvolumeで起動する。
sudo docker compose --env-file .env --profile dify up -d --wait dify-postgres

# plugin databaseを作成する。
sudo docker compose --env-file .env --profile dify up dify-postgres-init

# Dify本体databaseをPostgreSQL 18へrestoreする。
sudo docker run --rm --network "${STACK_NAME}_internal-nw" --env PGPASSWORD="$DIFY_DB_PASSWORD" --volume "${STACK_NAME}_dify-postgres-15-backup:/backup:ro" docker.io/library/postgres:18.7-alpine3.24 pg_restore -h dify-postgres -U "$DIFY_DB_USER" -d dify_db --clean --if-exists --no-owner --no-privileges --exit-on-error /backup/dify_db.dump

# plugin databaseをPostgreSQL 18へrestoreする。
sudo docker run --rm --network "${STACK_NAME}_internal-nw" --env PGPASSWORD="$DIFY_DB_PASSWORD" --volume "${STACK_NAME}_dify-postgres-15-backup:/backup:ro" docker.io/library/postgres:18.7-alpine3.24 pg_restore -h dify-postgres -U "$DIFY_DB_USER" -d dify_plugin --clean --if-exists --no-owner --no-privileges --exit-on-error /backup/dify_plugin.dump

# targetのPostgreSQL versionとtable数を確認する。
sudo docker compose --env-file .env --profile dify exec dify-postgres psql -U "$DIFY_DB_USER" -d dify_db -Atc "SELECT current_setting('server_version'); SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"
```

期待結果:

- 2つのdumpを`pg_restore --list`で読み取れる。
- PostgreSQL 18の両databaseに旧環境と同じschema、account、tenant、applicationが存在する。

失敗条件:

- dumpまたはrestoreでschema、extension、constraint、data errorが発生する。
- restore前後で主要tableのrow数が一致しない。

## Storageとcacheの切替

```bash
# RustFSとbucket初期化を起動する。
sudo docker compose --env-file .env --profile dify up -d --wait dify-rustfs
sudo docker compose --env-file .env --profile dify up dify-rustfs-bucket-init

# 旧storage volumeの全objectをDify bucketへ同期する。
sudo docker compose --env-file .env --profile dify run --rm --no-deps --volume "${STACK_NAME}_dify-storage:/source:ro" --entrypoint aws dify-rustfs-bucket-init s3 sync /source s3://dify-bucket/

# RustFS上のobject一覧を保存して同期結果を確認する。
sudo docker compose --env-file .env --profile dify run --rm --no-deps --entrypoint aws dify-rustfs-bucket-init s3 ls --recursive s3://dify-bucket/ | sudo tee "$DIFY_BACKUP_DIR/rustfs-objects.txt"

# emptyのValkeyを含むDify stack全体を起動する。
sudo docker compose --env-file .env --profile dify up -d

# service状態と公開endpointを確認する。
sudo docker compose --env-file .env --profile dify ps
curl -fsS "http://${PUBLIC_HOST:-localhost}:32100" >/dev/null
```

期待結果:

- 旧fileをUIからdownloadできる。
- Dify、plugin、agent、workerがhealthyになり、新しいworkflowを実行できる。
- Valkey接続errorがなく、切替前の未完了taskを再実行する必要がない。

失敗条件:

- RustFSのobject数またはsample fileの内容が旧storageと一致しない。
- database migration、S3、Valkey、Celery接続のerrorが出る。

## Rollback

新stackを停止し、旧Compose revisionで`dify-postgres-data`、`dify-storage`、`dify-redis-data`を再度mountする。切替後に作成または変更したdatabase record、file、task状態は旧volumeへ自動反映されない。

```bash
# 新しいDify stackを停止する。
sudo docker compose --env-file .env --profile dify down

# 旧volumeが削除されていないことを確認する。
sudo docker volume inspect "${STACK_NAME}_dify-postgres-data" "${STACK_NAME}_dify-storage" "${STACK_NAME}_dify-redis-data" >/dev/null
```

## References

- [Dify official Docker Compose](https://github.com/langgenius/dify/blob/main/docker/docker-compose.yaml)
- [PostgreSQL: Upgrading a cluster](https://www.postgresql.org/docs/current/upgrading.html)
- [RustFS SDK overview](https://docs.rustfs.com/en/developer/sdk)
- [Valkey: Migration from Redis](https://valkey.io/topics/migration/)
