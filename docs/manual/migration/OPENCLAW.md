# OpenClawの移行手順

## 対象

OpenClawのimage、state schema、session SQLite、managed config、Discord pluginを同じrelease cohortへ更新する。`openclaw-data`には認証、session、channel、pluginの状態が含まれるため、volumeを削除して更新してはならない（MUST NOT）。

## 事前条件

- `openclaw-init`と`openclaw`のimage tag、Discord plugin versionを同じrelease cohortへ固定する。
- Gatewayを停止してからraw volume backupを取得する。
- repository管理configは`openclaw-init`が書き込み可能なmanaged configへ複製し、Doctorのmigration結果をrepositoryへ反映する。
- backupにはcredentialが含まれるため、owner以外が読めない場所へ保存する。

## Backup

例はCompose project名`inferlab`を使用する。異なるproject名ではvolume名を読み替える。

```bash
# backupを識別するIDと保存先を設定する。
export OPENCLAW_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export OPENCLAW_BACKUP_DIR="/srv/backup/inferlab/openclaw/${OPENCLAW_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$OPENCLAW_BACKUP_DIR"

# Gatewayとinit serviceを停止してwriterを排除する。
sudo docker compose --env-file .env --profile inference --profile openclaw stop openclaw openclaw-init

# 停止中のstate volumeをraw archiveへ保存する。
sudo docker run --rm --network none --read-only --volume inferlab_openclaw-data:/source:ro --volume "$OPENCLAW_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/openclaw-data.tar.gz -C /source .'

# archiveのchecksumを保存して読み取り可能性を確認する。
sudo sha256sum "$OPENCLAW_BACKUP_DIR/openclaw-data.tar.gz" | sudo tee "$OPENCLAW_BACKUP_DIR/SHA256SUMS"
sudo tar -tzf "$OPENCLAW_BACKUP_DIR/openclaw-data.tar.gz" >/dev/null
```

期待結果:

- `openclaw-data.tar.gz`を読み取れる。
- `SHA256SUMS`にarchiveのchecksumが記録される。
- backup取得中にOpenClawのwriterが動作しない。

失敗条件:

- archive作成、一覧取得、checksumのいずれかが失敗する。
- volume名が実環境と一致しない。

失敗時は更新せず、Gatewayも旧imageのまま再起動する。

## 候補versionの適用

`10-inference/docker-compose.yml`で次を同じcommitとして更新する。

- `openclaw-init.image`
- `openclaw.image`
- `openclaw-init`が導入する`@openclaw/discord` version

```bash
# 更新後のCompose定義を検証する。
sudo docker compose --env-file .env --profile inference --profile openclaw config --quiet

# init serviceでmanaged config、plugin、Doctor migrationを適用する。
sudo docker compose --env-file .env --profile inference --profile openclaw up -d openclaw

# initとGatewayの状態を確認する。
sudo docker compose --env-file .env --profile inference --profile openclaw ps openclaw-init openclaw

# DoctorとGatewayの起動logを確認する。
sudo docker compose --env-file .env --profile inference --profile openclaw logs --no-log-prefix openclaw-init openclaw

# Gateway、Discord、session storeの状態を確認する。
sudo docker compose --env-file .env --profile inference --profile openclaw exec openclaw node dist/index.js health
```

期待結果:

- `openclaw-init`がexit code `0`で終了する。
- Doctorが`Doctor complete`を出力し、`openclaw`がrestartせずhealthyになる。
- Discordがconfiguredになり、既存sessionがhealth出力に残る。

失敗条件:

- `EBUSY`、migration custody、SQLite integrity errorが出る。
- restart countが増える、またはhealthが`starting`から収束しない。

## Managed configの反映

Doctorはmanaged configへmigration markerを書き戻す。次回initでrepository版に戻らないよう、runtime secretと`wizard.lastRun*`を除くschema差分をreviewして`10-inference/openclaw/openclaw.json`へ反映する。

```bash
# Doctor後のmanaged configをreview用に取り出す。
sudo docker cp inferlab-openclaw:/home/node/.openclaw/openclaw.managed.json "$OPENCLAW_BACKUP_DIR/openclaw.managed.json"

# repository版との差分を表示する。
diff -u 10-inference/openclaw/openclaw.json "$OPENCLAW_BACKUP_DIR/openclaw.managed.json" || true

# repository版を再投入するためGatewayを停止する。
sudo docker compose --env-file .env --profile inference --profile openclaw stop openclaw

# initを単独実行してrepository版をmanaged configへ複製する。
sudo docker compose --env-file .env --profile inference --profile openclaw run --rm --no-deps openclaw-init

# Gatewayを再起動してmigrationが再発しないことを確認する。
sudo docker compose --env-file .env --profile inference --profile openclaw start openclaw
sudo docker compose --env-file .env --profile inference --profile openclaw ps openclaw
```

期待結果:

- 2回目の起動で新しいschema migrationが発生しない。
- `openclaw`がrestart count `0`でhealthyになる。

## Rollback

rollbackでは失敗したvolumeを削除せず、backupを別volumeへ復元して旧Compose revisionから参照する。

```bash
# Gatewayを停止してrollback中の書込みを止める。
sudo docker compose --env-file .env --profile inference --profile openclaw stop openclaw openclaw-init

# rollback専用volumeを作成する。
sudo docker volume create inferlab_openclaw-data-rollback

# backupをrollback専用volumeへ復元する。
sudo docker run --rm --network none --read-only --volume inferlab_openclaw-data-rollback:/restore --volume "$OPENCLAW_BACKUP_DIR:/backup:ro" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -xzf /backup/openclaw-data.tar.gz -C /restore'
```

旧imageとrollback volumeを一時Compose overrideで指定し、healthとsessionを確認する。migration後に作成されたsessionはbackupへ含まれない。

## References

- [OpenClaw Docker](https://docs.openclaw.ai/install/docker)
- [OpenClaw Backups](https://docs.openclaw.ai/install/backups)
- [OpenClaw Doctor](https://docs.openclaw.ai/cli/doctor)
- [OpenClaw Updating](https://docs.openclaw.ai/install/updating)
