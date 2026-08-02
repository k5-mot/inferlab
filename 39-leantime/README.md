# 39-leantime

Leantimeを提供するproject management stack。代替検証用としてPlane構成も同じdirectoryに置いている。

## Leantimeの起動時初期化

`docker-compose.yml`のLeantimeは、MySQLがhealthyになった後に起動する。Leantime本体の初期schema作成はapplication entrypoint側で行う。

OIDCは環境変数で有効化している。

- `LEAN_OIDC_ENABLE`
- `LEAN_OIDC_CLIENT_ID`
- `LEAN_OIDC_CLIENT_SECRET`
- `LEAN_OIDC_PROVIDER_URL`
- `LEAN_OIDC_CREATE_USER`
- `LEAN_OIDC_DEFAULT_ROLE`

## Planeの起動時初期化

`docker-compose.plane.yml`はPlane検証用の構成で、`plane-migrator`がPostgreSQLとRedisのhealthy後にdatabase migrationを実行する。`plane-api`は`plane-migrator`の正常終了を待ってから起動する。

依存順序は次の通り。

1. `plane-postgres`、`plane-redis`、`plane-rabbitmq`、`plane-minio`を起動する。
2. `plane-migrator`がmigrationを実行する。
3. `plane-api`、worker、beat workerを起動する。
4. `plane-web`、`plane-space`、`plane-admin`、`plane-live`を起動する。
5. `plane-proxy`が公開endpointを起動する。

## Leantime起動

```bash
# Leantime stackを起動する。
sudo docker compose --env-file .env --profile leantime up -d leantime leantime-db
```

期待結果:

- `leantime-db`がhealthyになる。
- `leantime`が`http://${PUBLIC_HOST}:33900`で応答する。
- Keycloak OIDC loginを使ってuserが自動作成される。

失敗条件:

- MySQL初期化に失敗する。
- Leantime schema migrationが完了しない。
- Keycloak issuerへ到達できない。

## Plane起動

```bash
# Plane検証構成を起動する。
sudo docker compose --env-file .env -f 39-leantime/docker-compose.plane.yml --profile leantime up -d
```

期待結果:

- `plane-migrator`が`exited (0)`になる。
- `plane-api`、`plane-web`、`plane-proxy`がhealthyになる。
- `plane-proxy`が`http://${PUBLIC_HOST}:33900`で応答する。

失敗条件:

- `plane-migrator`がmigrationで失敗する。
- MinIO bucketまたはRabbitMQ vhost設定の不整合でAPIが起動しない。
- `plane-proxy`がupstream serviceへ接続できない。

## 確認手順

```bash
# Leantime profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile leantime ps

# 公開endpointの応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:33900" >/dev/null
```

期待結果:

- 使用中の構成に応じてLeantimeまたはPlaneの公開endpointが応答する。
- database serviceがhealthyになる。

失敗条件:

- 同じhost port `33900`をLeantime構成とPlane構成で同時に使用している。
- profileは同じ`leantime`だが、Compose fileの組み合わせが意図と異なる。

## 再初期化

Leantime構成を初期化し直す場合は、Leantime関連volumeを削除する。

```bash
# Leantime stackを停止する。
sudo docker compose --env-file .env --profile leantime down

# Leantime関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME:-inferlab}_leantime-db-data" "${STACK_NAME:-inferlab}_leantime-public-userfiles" "${STACK_NAME:-inferlab}_leantime-userfiles" "${STACK_NAME:-inferlab}_leantime-plugins" "${STACK_NAME:-inferlab}_leantime-logs"
```

期待結果:

- Leantime databaseとuser file volumeが削除される。

失敗条件:

- volumeが使用中で削除できない。
- Plane構成のvolumeと取り違える。
