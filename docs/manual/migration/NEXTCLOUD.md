# Nextcloud 34から35への移行手順

## 対象

Nextcloud `34.0.6`を35系へ1 majorずつ更新する。更新前に34系の最新point releaseへ揃え、第三者appの35対応を確認しなければならない（MUST）。databaseとdata volumeは同じ停止時点でbackupする。

## 事前確認とBackup

```bash
# 現在のNextcloud、database、app状態を記録する。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ status
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ app:list
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ config:list system > /tmp/nextcloud-system-config.json

# maintenance modeを有効にして利用者の書込みを止める。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ maintenance:mode --on

# NextcloudとValkeyを停止し、databaseだけをbackup可能な状態で残す。
sudo docker compose --env-file .env --profile nextcloud stop nextcloud nextcloud-valkey

# backup IDと保存先を設定する。
export NEXTCLOUD_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export NEXTCLOUD_BACKUP_DIR="/srv/backup/inferlab/nextcloud/${NEXTCLOUD_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$NEXTCLOUD_BACKUP_DIR"

# PostgreSQLをcustom archiveへdumpする。
sudo sh -c 'docker compose --env-file .env --profile nextcloud exec -T nextcloud-postgres pg_dump -U nc_db_user -d nextcloud_db --format=custom > "$1"' sh "$NEXTCLOUD_BACKUP_DIR/nextcloud.dump"

# databaseを停止してNextcloud volumeと同じ停止時点を固定する。
sudo docker compose --env-file .env --profile nextcloud stop nextcloud-postgres

# Nextcloud volumeをraw archiveへ保存する。
sudo docker run --rm --network none --read-only --volume inferlab_nextcloud:/source:ro --volume "$NEXTCLOUD_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/nextcloud-volume.tar.gz -C /source .'

# dump、archive、checksumを検証する。
sudo docker run --rm --network none --read-only --volume "$NEXTCLOUD_BACKUP_DIR:/backup:ro" --entrypoint pg_restore docker.io/library/postgres:18.7-alpine3.24 --list /backup/nextcloud.dump >/dev/null
sudo tar -tzf "$NEXTCLOUD_BACKUP_DIR/nextcloud-volume.tar.gz" >/dev/null
sudo sha256sum "$NEXTCLOUD_BACKUP_DIR/nextcloud.dump" "$NEXTCLOUD_BACKUP_DIR/nextcloud-volume.tar.gz" | sudo tee "$NEXTCLOUD_BACKUP_DIR/SHA256SUMS"
```

期待結果:

- `occ status`が34系最新point releaseと正常なdatabaseを報告する。
- `nextcloud.dump`と`nextcloud-volume.tar.gz`を読み取れる。
- `user_oidc`を含む第三者appの35対応版を事前取得できる。

失敗条件:

- 34系の未完了upgrade、background migration、file scanが残る。
- 必須appの35対応版がない、またはbackup検証が失敗する。

## 35系の適用

`30-nextcloud/docker-compose.yml`の`nextcloud.image`を、検証済みの35系point releaseへ固定する。app archiveとchecksumも同じ作業で35対応版へ更新する。

```bash
# 更新後のCompose定義を検証する。
sudo docker compose --env-file .env --profile nextcloud config --quiet

# 更新imageを取得する。
sudo docker compose --env-file .env --profile nextcloud pull

# database、Valkey、Nextcloudを更新imageで起動する。
sudo docker compose --env-file .env --profile nextcloud up -d --wait

# core database migrationを明示的に完了させる。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ upgrade

# 事前配置した35対応appが有効であることを確認する。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ app:list

# 推奨database修復を適用する。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ db:add-missing-indices
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ db:add-missing-primary-keys

# setup checkとmigration完了を確認する。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ setupchecks
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ status

# 検証完了後にmaintenance modeを解除する。
sudo docker compose --env-file .env --profile nextcloud exec --user www-data nextcloud php occ maintenance:mode --off
```

期待結果:

- `occ status`が35系、`installed: true`、`maintenance: false`を報告する。
- local loginとKeycloak OIDC login、file upload/download、共有、cronが動作する。
- `user_oidc`がEnabledで、setup checkにerrorがない。

失敗条件:

- `occ upgrade`、app update、database修復のいずれかが失敗する。
- 必須appがdisabledになる、OIDC loginまたは既存file参照が失敗する。

## Rollback

Nextcloud major upgrade後に旧imageへ戻してはならない（MUST NOT）。新stackを停止し、backupを別のNextcloud volumeと復元用databaseへ戻して、旧34系Compose revisionから参照する。切替後の変更はbackupへ含まれない。

```bash
# Nextcloud 35 stackを停止する。
sudo docker compose --env-file .env --profile nextcloud down

# rollback専用Nextcloud volumeを作成する。
sudo docker volume create inferlab_nextcloud-rollback

# raw archiveをrollback専用volumeへ復元する。
sudo docker run --rm --network none --read-only --volume inferlab_nextcloud-rollback:/restore --volume "$NEXTCLOUD_BACKUP_DIR:/backup:ro" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -xzf /backup/nextcloud-volume.tar.gz -C /restore'
```

旧34系image、rollback volume、復元用PostgreSQL volumeを一時Compose overrideで指定し、dumpをrestoreしてから起動する。

## References

- [Nextcloud: Upgrade via built-in updater](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/update.html)
- [Nextcloud: Upgrade manually](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/manual_upgrade.html)
- [Nextcloud: Upgrade overview](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/upgrade.html)
