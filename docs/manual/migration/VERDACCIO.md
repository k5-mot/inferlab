# Verdaccio 6から7への移行手順

## 対象

Verdaccio `6.11.3`からstable 7系へ、package storageとauth dataを保持して移行する。Verdaccio 7はNode.js 24、YAML config、package APIのBearer token、32文字のserver secretを要求する。本構成の公式containerはNode.js runtimeを同梱するため、hostへNode.jsを追加しない。

## 事前確認とBackup

旧`_auth`またはBasic認証を使う`.npmrc`は`_authToken`へ移行し、CIと`npm-importer`がBearer tokenを使うことを確認する。

```bash
# npm importerとVerdaccioを停止してstorageへの書込みを止める。
sudo docker compose --env-file .env --profile registry stop npm-importer verdaccio

# backup IDと保存先を設定する。
export VERDACCIO_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export VERDACCIO_BACKUP_DIR="/srv/backup/inferlab/verdaccio/${VERDACCIO_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$VERDACCIO_BACKUP_DIR"

# package、auth、token databaseを含むstorage volumeを保存する。
sudo docker run --rm --network none --read-only --volume inferlab_verdaccio-storage:/source:ro --volume "$VERDACCIO_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/verdaccio-storage.tar.gz -C /source .'

# repository管理configをbackupへ保存する。
sudo cp 12-registry/verdaccio/config.yaml "$VERDACCIO_BACKUP_DIR/config.yaml"

# archiveとchecksumを検証する。
sudo tar -tzf "$VERDACCIO_BACKUP_DIR/verdaccio-storage.tar.gz" >/dev/null
sudo sha256sum "$VERDACCIO_BACKUP_DIR/verdaccio-storage.tar.gz" "$VERDACCIO_BACKUP_DIR/config.yaml" | sudo tee "$VERDACCIO_BACKUP_DIR/SHA256SUMS"

# storage databaseを読んでserver secretの長さだけを表示する。
sudo docker run --rm --network none --read-only --volume inferlab_verdaccio-storage:/storage:ro docker.io/library/node:24.22.3-alpine3.24 node -e 'const fs=require("fs"); const p=["/storage/.verdaccio-db.json","/storage/.verdaccio-db"].find(fs.existsSync); if(!p) throw new Error("storage database not found"); const n=JSON.parse(fs.readFileSync(p,"utf8")).secret?.length; console.log(n ?? "missing")'
```

期待結果:

- archiveを読み取れ、server secretが32文字である。
- configがYAMLで、利用中のclientとimporterがBearer tokenを使用する。

失敗条件:

- server secretが32文字でない、またはstorage databaseを読めない。
- custom pluginがVerdaccio 7またはExpress 5へ未対応である。

secretが32文字でない場合は、Verdaccio 6で`security.api.migrateToSecureLegacySignature: true`を一時指定して変換し、全tokenを再発行してからbackupを取り直す。secret変更は既存tokenを無効化する。

## 隔離copyでの検証

本番volumeをVerdaccio 7へ直接mountしてはならない（MUST NOT）。

```bash
# 検証専用volumeを作成する。
sudo docker volume create inferlab_verdaccio-storage-v7-candidate

# backupを検証専用volumeへ復元する。
sudo docker run --rm --network none --read-only --volume inferlab_verdaccio-storage-v7-candidate:/restore --volume "$VERDACCIO_BACKUP_DIR:/backup:ro" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -xzf /backup/verdaccio-storage.tar.gz -C /restore'

# 固定したVerdaccio 7 imageで隔離copyを起動する。
sudo docker run --detach --name inferlab-verdaccio-v7-candidate --publish 127.0.0.1:4874:4873 --volume inferlab_verdaccio-storage-v7-candidate:/verdaccio/storage --volume "$PWD/12-registry/verdaccio/config.yaml:/verdaccio/conf/config.yaml:ro" docker.io/verdaccio/verdaccio:7.0.0

# 起動logとping endpointを確認する。
sudo docker logs inferlab-verdaccio-v7-candidate
curl -fsS http://127.0.0.1:4874/-/ping >/dev/null

# package metadataと既存tarballを取得できることを確認する。
npm ping --registry http://127.0.0.1:4874/
npm view '<既存package名>' version --registry http://127.0.0.1:4874/

# 検証containerを停止して削除する。
sudo docker rm --force inferlab-verdaccio-v7-candidate
```

既存tokenで`npm whoami`、既存packageのinstall、使い捨てpackageのpublishとinstallも検証する。`<既存package名>`は実在するpackageへ置き換える。

期待結果:

- Verdaccio 7がsecret、config、storage errorなしで起動する。
- scoped packageを含む既存packageを取得でき、Bearer tokenでpublishできる。

失敗条件:

- secret length、config schema、plugin、Basic authentication errorが出る。
- package metadata、tarball、token databaseのいずれかを読めない。

## 本番切替

隔離検証で使用した7系patch versionへ`12-registry/docker-compose.yml`のimageを固定する。

```bash
# 更新後のCompose定義を検証する。
sudo docker compose --env-file .env --profile registry config --quiet

# Verdaccio 7 imageを取得する。
sudo docker compose --env-file .env --profile registry pull verdaccio

# Verdaccioとimporterを起動する。
sudo docker compose --env-file .env --profile registry up -d --wait verdaccio npm-importer

# endpoint、service状態、import logを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:31201/-/ping" >/dev/null
sudo docker compose --env-file .env --profile registry ps verdaccio npm-importer
sudo docker compose --env-file .env --profile registry logs --no-log-prefix verdaccio npm-importer
```

期待結果:

- Verdaccioとimporterがhealthyになり、既存packageのinstallと新規publishが成功する。
- air-gap設定を維持し、外部uplinkへ接続しない。

失敗条件:

- importerのtokenが無効、またはpublish APIがBasic認証として拒否される。
- package metadataまたはtarballが欠落する。

## Rollback

新規publishを止め、Verdaccio 7を停止して、backupから別volumeへ復元したstorageをVerdaccio 6.11.3で起動する。7へ切替後のpublishを破棄できない場合は、先に追加packageとmetadataをexportする。

```bash
# Verdaccio 7とimporterを停止する。
sudo docker compose --env-file .env --profile registry stop npm-importer verdaccio

# rollback用volumeを作成する。
sudo docker volume create inferlab_verdaccio-storage-rollback

# 検証済みbackupをrollback用volumeへ復元する。
sudo docker run --rm --network none --read-only --volume inferlab_verdaccio-storage-rollback:/restore --volume "$VERDACCIO_BACKUP_DIR:/backup:ro" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -xzf /backup/verdaccio-storage.tar.gz -C /restore'
```

旧imageとrollback volumeを一時Compose overrideで指定して起動し、installとpublishを再検証する。

## References

- [Verdaccio version support policy](https://github.com/verdaccio/verdaccio/blob/master/VERSIONS.md)
- [Migrating from Verdaccio 6 to Verdaccio 7](https://www.verdaccio.org/blog/2026/09/27/verdaccio-6-to-7-migration/)
- [What's new in Verdaccio 7](https://www.verdaccio.org/blog/2026/10/25/verdaccio-7-release/)
- [Verdaccio configuration](https://www.verdaccio.org/docs/configuration/)
