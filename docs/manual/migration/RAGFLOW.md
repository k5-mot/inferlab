# RAGFlow 0.xから1.xへの移行手順

## 現在の停止条件

現在のstackはRAGFlow `0.27.3`である。公式経路は、すべての0.x環境が`0.27.2`を起動して検証した後、`1.0.0-rc1`へ移行し、そこから1.xへ進むことを要求している。同時にcheckpointのdowngradeを禁止しているため、`0.27.3`から`0.27.2`へ戻してはならない（MUST NOT）。

`0.27.3`からの公式経路が公開されるか、upstreamから書面で手順を得るまでは、本番migrationを開始してはならない（MUST NOT）。以下はvendorへ問い合わせる前に取得するrecovery pointの手順である。

## Recovery pointの作成

新しいdocument upload、parse、agent実行を止め、task queueが空になってから実行する。

```bash
# backup IDと保存先を設定する。
export RAGFLOW_COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-inferlab}"
export RAGFLOW_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export RAGFLOW_BACKUP_DIR="/srv/backup/inferlab/ragflow/${RAGFLOW_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$RAGFLOW_BACKUP_DIR"

# RAGFlow applicationを停止してmiddlewareへの書込みを止める。
sudo docker compose --env-file .env --profile ragflow stop ragflow

# MySQL全databaseをsingle transactionで論理dumpする。
sudo sh -c 'docker compose --env-file .env --profile ragflow exec -T ragflow-mysql sh -euc '\''exec mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" --single-transaction --routines --events --all-databases'\'' > "$1"' sh "$RAGFLOW_BACKUP_DIR/mysql.sql"

# RustFS bucketをfile単位でbackupする。
sudo docker compose --env-file .env --profile ragflow run --rm --no-deps --volume "$RAGFLOW_BACKUP_DIR:/backup" --entrypoint aws ragflow-rustfs-bucket-init s3 sync s3://ragflow-bucket /backup/rustfs

# 全middlewareを停止してraw volumeの時点を固定する。
sudo docker compose --env-file .env --profile ragflow stop ragflow-opensearch ragflow-mysql ragflow-rustfs ragflow-valkey

# OpenSearch、MySQL、RustFS、Valkey、log volumeをraw archiveへ保存する。
for volume in ragflow-opensearch-data ragflow-mysql-data ragflow-rustfs-data ragflow-valkey-data ragflow-logs; do sudo docker run --rm --network none --read-only --volume "${RAGFLOW_COMPOSE_PROJECT}_${volume}:/source:ro" --volume "$RAGFLOW_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c "tar -czf /backup/${volume}.tar.gz -C /source ."; done

# archiveと論理backupのchecksumを保存する。
sudo sha256sum "$RAGFLOW_BACKUP_DIR"/mysql.sql "$RAGFLOW_BACKUP_DIR"/*.tar.gz | sudo tee "$RAGFLOW_BACKUP_DIR/SHA256SUMS"

# archiveをすべて読み取れることを確認する。
for archive in "$RAGFLOW_BACKUP_DIR"/*.tar.gz; do sudo tar -tzf "$archive" >/dev/null; done
```

期待結果:

- MySQL dump、RustFS object、全raw volume archiveを同じ停止期間で取得できる。
- checksumとarchive検査が成功し、旧volumeが残る。

失敗条件:

- 実行中taskまたはwriterが残る。
- MySQL dump、S3 sync、archive、checksumのいずれかが失敗する。
- recovery pointから隔離環境へ全middlewareを復元できない。

## 公式経路確定後の実行順序

upstreamが`0.27.3`からの経路を公開した後、次を別の保守作業として実施する。

1. recovery pointを隔離環境へ復元する。
2. upstreamが指定した0.x checkpointを1つずつ起動し、各checkpointでuser、dataset、document、retrieval、model provider、agentを検証する。
3. `1.0.0-rc1`へ移行し、自動data migrationを完了させる。この境界は不可逆である。
4. NATSがtask queue、Kvrocksがcacheとcheckpointを担当する1.x構成へComposeを更新する。
5. rc1以降のrequired checkpointを順に起動し、stable 1.xへ進む。
6. 最終versionで既存documentのretrievalと新規documentのparseを検証する。

各checkpointをimage tagの書換えだけで通過してはならない（MUST NOT）。必ず起動とmigration log確認を行う。

## Rollback

1.x境界を越えたdataを0.xへdowngradeしてはならない（MUST NOT）。失敗時は新stackを停止し、recovery pointのMySQL、OpenSearch、RustFS、Valkeyを同じ時点へ一括復元して`0.27.3`を起動する。migration開始後の変更は失われる。

```bash
# 失敗したRAGFlow stackを停止する。
sudo docker compose --env-file .env --profile ragflow down

# 旧volumeが保持されていることを確認する。
sudo docker volume inspect inferlab_ragflow-opensearch-data inferlab_ragflow-mysql-data inferlab_ragflow-rustfs-data inferlab_ragflow-valkey-data >/dev/null
```

## References

- [RAGFlow: Upgrade from v0.x to v1.x](https://ragflow.io/docs/upgrade_from_v0_to_v1)
- [RAGFlow 1.0 release notes](https://ragflow.io/docs/v1.0.0/release_notes)
- [RAGFlow: Backup and restore v0.x](https://ragflow.io/docs/backup_and_restore_v0)
