# 22-ragflow

RAGFlow、Elasticsearch、MySQL、RustFS、ValkeyをまとめたRAG platform stack。

RAGFlow 0.26.4の公式Docker Composeを基準に、次の変更を加えている。

- object storageはMinIO互換APIを提供するRustFSを使用する。
- cacheとtask queueは、RAGFlow公式構成と同じValkeyをversion固定して使用する。
- document engineはElasticsearchを使用する。
- RAGFlow imageに同梱された設定templateとentrypointを使用し、service接続先は環境変数で指定する。

## 構成

| Service | 用途 | Host port |
| --- | --- | --- |
| `ragflow` | Web UI、REST API、task executor | `32200`、`32201` |
| `ragflow-elasticsearch` | document indexとvector検索 | - |
| `ragflow-mysql` | application database | - |
| `ragflow-rustfs` | S3互換object storageと管理console | `32202`、`32203` |
| `ragflow-rustfs-bucket-init` | `ragflow-bucket`の冪等作成 | - |
| `ragflow-valkey` | cache、lock、task queue | - |

RAGFlow公式imageはx86_64向けであり、起動にはDocker 24.0.0以上、Docker Compose 2.26.1以上、CPU 4 core以上、memory 16 GB以上、disk 50 GB以上が必要である（MUST）。文書解析やembedding生成に使用する外部modelのresourceは、この要件へ追加して見積もる。

## 起動

repository rootで実行する。

```bash
# RAGFlow stackを起動する。
sudo docker compose --env-file .env --profile ragflow up -d
```

期待結果:

- `ragflow-rustfs-bucket-init`が`exited (0)`になる。
- Elasticsearch、MySQL、RustFS、Valkeyがhealthyになる。
- RAGFlowがdatabase migrationを完了し、healthyになる。
- Web UIが`http://${PUBLIC_HOST}:32200`で応答する。

失敗条件:

- hostのmemoryまたはdisk不足によりElasticsearchかRAGFlowが終了する。
- RustFSのcredential不一致により`ragflow-bucket`を作成できない。
- MySQLまたはElasticsearchの初期化がRAGFlowのhealthcheck開始期間内に完了しない。
- hostの`32200`から`32203`までの使用portが他processと競合する。

## 確認手順

```bash
# RAGFlow profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile ragflow ps

# RAGFlowの統合health endpointで全middleware接続を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32201/api/v1/system/healthz"

# RAGFlow Web UIの応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32200" >/dev/null

# RustFSのS3 APIでRAGFlow bucketを確認する。
sudo docker compose --env-file .env --profile ragflow run --rm --entrypoint aws ragflow-rustfs-bucket-init s3api head-bucket --bucket ragflow-bucket

# ValkeyへRAGFlowと同じpasswordで接続できることを確認する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-valkey valkey-cli -a "${RAGFLOW_VALKEY_PASSWORD:-ragflow_valkey_password}" ping
```

期待結果:

- `ragflow`、`ragflow-elasticsearch`、`ragflow-mysql`、`ragflow-rustfs`、`ragflow-valkey`がhealthyになる。
- 統合health endpointがHTTP 200を返し、`db`、`redis`、`doc_engine`、`storage`がすべて`ok`になる。
- RustFSのbucket確認が成功し、Valkeyが`PONG`を返す。

失敗条件:

- 統合health endpointがHTTP 500を返し、いずれかのmiddlewareが`nok`になる。
- RAGFlow logがdatabase migration、Elasticsearch認証、object storage接続のerrorを出力する。
- task executor heartbeatが登録されず、文書解析taskが開始されない。

## Model設定

RAGFlow 0.22.0以降の公式imageはembedding modelを同梱しない。初回login後にRAGFlowのmodel provider設定から、既存のLiteLLM、TEI、または外部providerを登録しなければならない（MUST）。model providerを設定するまではUIとmiddlewareがhealthyでも文書のembedding生成やchatを実行できない。

## Credential設定

productionでは`.env`に次の値を設定し、既定値を使用してはならない（MUST NOT）。

- `RAGFLOW_ELASTIC_PASSWORD`
- `RAGFLOW_SECRET_KEY`（32文字以上）
- `RAGFLOW_MYSQL_PASSWORD`
- `RAGFLOW_RUSTFS_ACCESS_KEY`
- `RAGFLOW_RUSTFS_SECRET_KEY`
- `RAGFLOW_VALKEY_PASSWORD`

credentialを変更する場合、既存volumeが初期化済みの状態で環境変数だけを変更してはならない（MUST NOT）。各middleware側のcredential更新またはbackupからの再初期化を同じ保守作業で実施する。

## 再初期化

次の手順はRAGFlowのuser、dataset、document、index、objectをすべて削除する。必要なdataをbackupしてから実行しなければならない（MUST）。

```bash
# RAGFlow stackを停止する。
sudo docker compose --env-file .env --profile ragflow down

# RAGFlow関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_ragflow-logs" "${STACK_NAME}_ragflow-elasticsearch-data" "${STACK_NAME}_ragflow-mysql-data" "${STACK_NAME}_ragflow-rustfs-data" "${STACK_NAME}_ragflow-valkey-data"

# 空のvolumeでRAGFlow stackを再作成する。
sudo docker compose --env-file .env --profile ragflow up -d
```

期待結果:

- middlewareとdatabase schemaが空のvolumeへ再作成される。
- RAGFlowの初回user登録画面が表示される。

失敗条件:

- containerが停止しておらずvolumeを削除できない。
- resource不足またはcredential不一致により再作成後のhealthcheckが失敗する。

rollbackする場合は、再初期化前に取得したMySQL、Elasticsearch、RustFSの整合したbackupを同時点へ復元する。いずれか1つのmiddlewareだけを異なる時点へ戻してはならない（MUST NOT）。

## References

- [RAGFlow 0.26.4 Docker Compose](https://github.com/infiniflow/ragflow/blob/v0.26.4/docker/docker-compose.yml)
- [RAGFlow 0.26.4 middleware Compose](https://github.com/infiniflow/ragflow/blob/v0.26.4/docker/docker-compose-base.yml)
- [RAGFlow Docker deployment requirements](https://github.com/infiniflow/ragflow/tree/v0.26.4?tab=readme-ov-file#-start-up-the-server)
- [RAGFlow MinIO-compatible storage client](https://github.com/infiniflow/ragflow/blob/v0.26.4/rag/utils/minio_conn.py)
- [RustFS SDK overview and S3 compatibility](https://docs.rustfs.com/en/developer/sdk)
- [Valkey compatibility and Redis migration](https://valkey.io/topics/migration/)
