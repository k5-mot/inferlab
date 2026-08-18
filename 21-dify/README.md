# 21-dify

Dify、plugin daemon、agent backend、sandbox、PostgreSQL、Redis、Qdrant、nginxをまとめたworkflow stack。

## 起動時初期化

このstackには複数の依存付き初期化処理がある。

| Service | 初期化内容 |
| --- | --- |
| `dify-init-permissions` | Compose内のinit commandで`dify-storage` volumeのownerをDify実行userへ変更し、`.init_permissions` stampを作成する。 |
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

- `dify-init-permissions`と`dify-postgres-init`が正常終了する。
- `dify-api`、`dify-worker`、`dify-web`、`dify-plugin-daemon`がhealthyになる。
- `dify-nginx`が`http://${PUBLIC_HOST}:32100`で応答する。

失敗条件:

- `dify-storage` volumeの権限変更に失敗する。
- `dify_plugin` databaseの作成に失敗する。
- Redis passwordやplugin daemon keyの不一致でservice間通信が失敗する。
- `dify-agent-backend`または`dify-local-sandbox`が起動せず、agent系機能が使えない。

## 確認手順

```bash
# Dify profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile dify ps

# Dify公開endpointの応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32100" >/dev/null

# plugin daemonのhealth endpointを確認する。
sudo docker compose --env-file .env --profile dify exec dify-plugin-daemon curl -fsS http://127.0.0.1:5002/health/check >/dev/null
```

期待結果:

- `dify-init-permissions`と`dify-postgres-init`が`exited (0)`になる。
- Difyの初回セットアップ画面またはlogin画面が表示される。
- plugin daemon healthcheckが成功する。

失敗条件:

- `dify-api` logにmigration失敗が出る。
- `dify-plugin-daemon` logにdatabase接続失敗が出る。
- `dify-nginx`がupstreamへ接続できない。

## 再初期化

Difyを完全に初期化し直す場合は、Dify関連volumeを削除する。既存workflow、user、plugin、vector dataを失う。

```bash
# Dify stackを停止する。
sudo docker compose --env-file .env --profile dify down

# Dify関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_dify-storage" "${STACK_NAME}_dify-plugin-daemon" "${STACK_NAME}_dify-postgres-data" "${STACK_NAME}_dify-redis-data" "${STACK_NAME}_dify-qdrant-storage" "${STACK_NAME}_dify-qdrant-snapshots"

# Dify stackを再作成する。
sudo docker compose --env-file .env --profile dify up -d
```

期待結果:

- Difyの初回セットアップが再表示される。
- permission初期化とdatabase初期化が再実行される。

失敗条件:

- volumeが使用中で削除できない。
- 初回セットアップ後もworkerがhealthyにならない。
