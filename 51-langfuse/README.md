# 51-langfuse

Langfuse、worker、PostgreSQL、ClickHouse、Valkey、RustFSをまとめたLLM observability stack。

## 起動時初期化

このstackには次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `langfuse-rustfs-bucket-init` | Compose内のinit commandでRustFSがhealthyになった後、`langfuse-bucket`が無ければ作成する。 |
| `langfuse-web` | `LANGFUSE_INIT_*`で初期org、project、user、project keyを作成する。 |
| `langfuse-worker` | ClickHouse、PostgreSQL、Valkey、RustFS bucketの準備完了後にevent処理workerを起動する。 |
| `langfuse-clickhouse` | Prometheus scrape用のClickHouse設定を`clickhouse/prometheus.xml`から読み込む。 |

Langfuseの初期project keyは`LANGFUSE_PUBLIC_KEY`と`LANGFUSE_SECRET_KEY`で指定する。LiteLLMやOpenClawはこの値を使ってtraceを送信する。

## 起動

```bash
# Langfuse stackを起動する。
sudo docker compose --env-file .env --profile langfuse up -d
```

期待結果:

- PostgreSQL、ClickHouse、Valkey、RustFSがhealthyになる。
- `langfuse-rustfs-bucket-init`が正常終了する。
- `langfuse-web`が`http://${PUBLIC_HOST}:35100`で応答する。
- 初期org、project、user、project keyが作成される。

失敗条件:

- RustFS bucket作成が認証エラーになる。
- `ENCRYPTION_KEY`、`SALT`、`NEXTAUTH_SECRET`などの値が既存DBと不整合になる。
- ClickHouse migrationに失敗する。
- PostgreSQL major versionと既存data directoryが不整合になる。

## 確認手順

```bash
# Langfuse profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile langfuse ps

# Langfuse public health endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:35100/api/public/health" >/dev/null

# RustFS bucket初期化serviceの終了状態を確認する。
sudo docker compose --env-file .env --profile langfuse ps langfuse-rustfs-bucket-init
```

期待結果:

- `langfuse-rustfs-bucket-init`が`exited (0)`になる。
- `langfuse-web`と`langfuse-worker`がhealthyになる。
- Langfuse UIで初期projectが見える。

失敗条件:

- `langfuse-worker`がqueueまたはClickHouse接続エラーで再起動する。
- Langfuse UIで初期user loginに失敗する。
- S3 event upload endpointへ接続できない。

## データ保持期間

Langfuseのtrace保持期間はproject単位で管理する。初期projectを7日保持へ制限する場合は、Langfuse起動後にPostgreSQL上のproject設定を更新する。

```bash
# 初期projectのtrace保持期間を7日に設定する。
sudo docker compose --env-file .env --profile langfuse exec -T langfuse-postgres psql -U postgres_user -d langfuse_db -v ON_ERROR_STOP=1 -c "UPDATE projects SET retention_days = 7, updated_at = now() WHERE id = 'prg0' AND deleted_at IS NULL AND retention_days IS DISTINCT FROM 7;"

# 初期projectのtrace保持期間を確認する。
sudo docker compose --env-file .env --profile langfuse exec -T langfuse-postgres psql -U postgres_user -d langfuse_db -Atc "SELECT id, retention_days FROM projects WHERE id = 'prg0';"
```

期待結果:

- 更新commandが`UPDATE 1`または`UPDATE 0`を返す。`UPDATE 0`はすでに7日に設定済みであることを示す。
- 確認commandが`prg0|7`を返す。

失敗条件:

- `langfuse-postgres`が起動していない。
- `projects` tableまたは`prg0` projectがまだ作成されていない。
- 確認commandの`retention_days`が空または`7`以外になる。

## 再初期化

Langfuseを完全に初期化し直す場合は、関連volumeを削除する。trace、project、API key、event objectを失う。

```bash
# Langfuse stackを停止する。
sudo docker compose --env-file .env --profile langfuse down

# Langfuse関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_langfuse_clickhouse_data" "${STACK_NAME}_langfuse_clickhouse_logs" "${STACK_NAME}_langfuse_valkey_data" "${STACK_NAME}_langfuse_postgres_data" "${STACK_NAME}_langfuse_rustfs_data"

# Langfuse stackを再作成する。
sudo docker compose --env-file .env --profile langfuse up -d
```

期待結果:

- ClickHouse、PostgreSQL、Valkey、RustFSが空の状態で再作成される。
- `LANGFUSE_INIT_*`による初期project作成が再実行される。

失敗条件:

- volumeが使用中で削除できない。
- 既存のLiteLLM/OpenClaw側project keyと新規project keyが一致しない。
