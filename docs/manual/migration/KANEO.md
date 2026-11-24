# KaneoのPostgreSQL 16から18への移行手順

## 対象

KaneoのPostgreSQL 16 clusterをPostgreSQL 18へ移し、Kaneo起動時のapplication migrationを適用する。PostgreSQL major間でdata directoryを直接再利用してはならない（MUST NOT）。PostgreSQL 18のvolumeは`/var/lib/postgresql`へmountする。

## 事前確認とBackup

例はCompose project名`inferlab`、旧volume名`inferlab_kaneo-postgres-data`を使用する。

```bash
# migration中の書込みを止める。
sudo docker compose --env-file .env --profile kaneo stop kaneo kaneo-postgres

# backupを識別するIDと保存先を設定する。
export KANEO_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export KANEO_BACKUP_DIR="/srv/backup/inferlab/kaneo/${KANEO_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$KANEO_BACKUP_DIR"

# 旧volumeを停止中のraw archiveへ保存する。
sudo docker run --rm --network none --read-only --volume inferlab_kaneo-postgres-data:/source:ro --volume "$KANEO_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/kaneo-postgres-16-data.tar.gz -C /source .'

# raw archiveを検証する。
sudo tar -tzf "$KANEO_BACKUP_DIR/kaneo-postgres-16-data.tar.gz" >/dev/null
sudo sha256sum "$KANEO_BACKUP_DIR/kaneo-postgres-16-data.tar.gz" | sudo tee "$KANEO_BACKUP_DIR/SHA256SUMS"
```

期待結果:

- PostgreSQL 16の停止中snapshotを読み取れる。
- 旧volumeが削除されず残る。

失敗条件:

- volumeが使用中、空、またはarchiveを読み取れない。

## 論理dump

```bash
# 旧volumeをPostgreSQL 16で一時起動する。
sudo docker run --detach --name inferlab-kaneo-postgres-16-source --env POSTGRES_PASSWORD=kaneo_db_password --volume inferlab_kaneo-postgres-data:/var/lib/postgresql/data --volume "$KANEO_BACKUP_DIR:/backup" docker.io/library/postgres:16.15-alpine

# source databaseが接続可能になるまで確認する。
sudo docker exec inferlab-kaneo-postgres-16-source pg_isready -U kaneo_db_user -d kaneo

# Kaneo databaseをcustom archiveへdumpする。
sudo docker exec inferlab-kaneo-postgres-16-source pg_dump -U kaneo_db_user -d kaneo --format=custom --file=/backup/kaneo.dump

# dumpの目録を読み取れることを確認する。
sudo docker exec inferlab-kaneo-postgres-16-source pg_restore --list /backup/kaneo.dump >/dev/null

# source containerを停止して削除する。
sudo docker rm --force inferlab-kaneo-postgres-16-source
```

期待結果:

- `kaneo.dump`を`pg_restore --list`で読み取れる。
- dump中にapplicationから書込みが発生しない。

## PostgreSQL 18へのRestore

`32-kaneo/docker-compose.yml`が`kaneo-postgres-18-data:/var/lib/postgresql`を使用することを確認してから進む。

```bash
# PostgreSQL 18だけを起動してhealthyになるまで待つ。
sudo docker compose --env-file .env --profile kaneo up -d --wait kaneo-postgres

# dumpをtarget containerへ複製する。
sudo docker cp "$KANEO_BACKUP_DIR/kaneo.dump" inferlab-kaneo-postgres:/tmp/kaneo.dump

# 初期databaseへschemaとdataをrestoreする。
sudo docker compose --env-file .env --profile kaneo exec kaneo-postgres pg_restore -U kaneo_db_user -d kaneo --clean --if-exists --no-owner --no-privileges --exit-on-error /tmp/kaneo.dump

# restore後のversionとpublic table数を確認する。
sudo docker compose --env-file .env --profile kaneo exec kaneo-postgres psql -U kaneo_db_user -d kaneo -Atc "SELECT current_setting('server_version'); SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public';"

# Kaneoを起動してapplication migrationを実行する。
sudo docker compose --env-file .env --profile kaneo up -d --wait kaneo

# application migrationとhealthを確認する。
sudo docker compose --env-file .env --profile kaneo logs --no-log-prefix kaneo
sudo docker compose --env-file .env --profile kaneo ps kaneo kaneo-postgres
```

期待結果:

- PostgreSQLが18.xを報告する。
- Kaneo logに`Database migrated successfully`が出る。
- KaneoとPostgreSQLがhealthyになり、既存projectとtaskを読み書きできる。

失敗条件:

- restoreでschema、constraint、data errorが発生する。
- restore前後で主要tableのrow数が一致しない。
- Kaneoのapplication migrationが失敗する。

## Rollback

新stackを停止し、旧Compose revisionで`inferlab_kaneo-postgres-data`を再度mountする。PostgreSQL 18へ切替後の書込みは旧volumeへ反映されないため、rollback判断までは利用者の書込みを許可しないか、差分を別途exportする。

```bash
# 新しいKaneo stackを停止する。
sudo docker compose --env-file .env --profile kaneo down

# 旧volumeが残っていることを確認する。
sudo docker volume inspect inferlab_kaneo-postgres-data >/dev/null
```

## References

- [PostgreSQL: Upgrading a cluster](https://www.postgresql.org/docs/current/upgrading.html)
- [PostgreSQL official image: PGDATA](https://hub.docker.com/_/postgres#pgdata)
- [Kaneo releases](https://github.com/usekaneo/kaneo/releases)
