# ZulipのRedis 8からValkey 9への移行手順

## 対象

Redis 8が生成したRDB version 14を、互換性のないValkey 9へ直接読み込まず、新しいempty volumeへ切り替える。本環境の`dump.rdb`はchecksum正常、key 0件、expire 0件である。keyが1件でも存在する場合はこのempty migrationを実施してはならない（MUST NOT）。

## BackupとRDB検査

```bash
# Zulip profileを停止してRedisへの書込みを止める。
sudo docker compose --env-file .env --profile zulip stop

# backupを識別するIDと保存先を設定する。
export ZULIP_MIGRATION_ID="$(date +%Y%m%d-%H%M%S)"
export ZULIP_BACKUP_DIR="/srv/backup/inferlab/zulip/${ZULIP_MIGRATION_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
sudo install -d -m 700 "$ZULIP_BACKUP_DIR"

# 旧Redis volumeをraw archiveへ保存する。
sudo docker run --rm --network none --read-only --volume inferlab_zulip-redis-data:/source:ro --volume "$ZULIP_BACKUP_DIR:/backup" --entrypoint /bin/sh docker.io/library/node:24.22.3-alpine3.24 -c 'tar -czf /backup/zulip-redis-data.tar.gz -C /source .'

# RDBをRedis 8の検査toolでread-only検証する。
sudo docker run --rm --network none --read-only --volume inferlab_zulip-redis-data:/data:ro --entrypoint redis-check-rdb docker.io/library/redis:8.12.0-alpine /data/dump.rdb | sudo tee "$ZULIP_BACKUP_DIR/redis-check-rdb.txt"

# backupのchecksumを保存する。
sudo sha256sum "$ZULIP_BACKUP_DIR/zulip-redis-data.tar.gz" | sudo tee "$ZULIP_BACKUP_DIR/SHA256SUMS"
```

期待結果:

- `Checksum OK`、`0 keys read`、`0 expires`が記録される。
- 旧volumeとraw archiveが残る。

失敗条件:

- checksum error、1件以上のkey、RDB parse errorがある。

keyが存在する場合、Redis 8互換imageでvolume copyを起動し、data typeごとの論理export/importまたはZulip側での再生成可否を個別評価する。Redis 8のRDBをValkey 9へ直接渡してはならない（MUST NOT）。

## Empty volumeへの切替

`33-zulip/docker-compose.yml`のvolume名を`zulip-redis-data`から`zulip-valkey-9-data`へ変更し、旧volumeをCompose管理外に残す。

```bash
# 更新後のCompose定義を検証する。
sudo docker compose --env-file .env --profile zulip config --quiet

# Valkeyだけを新しいvolumeで起動する。
sudo docker compose --env-file .env --profile zulip up -d --no-deps zulip-redis

# Valkeyのhealthと空keyspaceを確認する。
sudo docker compose --env-file .env --profile zulip exec zulip-redis sh -euc 'VALKEYCLI_AUTH="$REDIS_PASSWORD" valkey-cli ping; VALKEYCLI_AUTH="$REDIS_PASSWORD" valkey-cli dbsize'

# Zulip profile全体を起動する。
sudo docker compose --env-file .env --profile zulip up -d

# service状態とZulip endpointを確認する。
sudo docker compose --env-file .env --profile zulip ps
curl -kfsS "https://${PUBLIC_HOST:-localhost}:33300/" >/dev/null
```

期待結果:

- Valkeyが`PONG`と`0`を返してhealthyになる。
- Zulipへloginでき、message送受信、notification、background jobが動作する。

失敗条件:

- Valkeyが旧RDBを読み込もうとする。
- ZulipがRedis認証、queue、sessionに関するerrorを出す。
- message送受信またはbackground jobが失敗する。

## Rollback

新profileを停止し、Composeのvolume名を`zulip-redis-data`へ戻してRedis 8互換imageを指定する。新Valkey側のcacheや一時状態は旧volumeへ戻らない。

```bash
# 新しいZulip profileを停止する。
sudo docker compose --env-file .env --profile zulip down

# 旧volumeが保持されていることを確認する。
sudo docker volume inspect inferlab_zulip-redis-data >/dev/null
```

rollback期間終了後も、backupのchecksum検証と利用者確認が完了するまで旧volumeを削除してはならない（MUST NOT）。

## References

- [Valkey: Migration from Redis](https://valkey.io/topics/migration/)
- [Valkey release compatibility](https://valkey.io/topics/releases/)
- [Zulip Docker Compose](https://github.com/zulip/docker-zulip/blob/main/compose.yaml)
