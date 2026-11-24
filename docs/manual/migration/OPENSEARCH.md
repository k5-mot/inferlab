# RAGFlow用OpenSearch 2から3への移行手順

## 対象と実施条件

RAGFlowのOpenSearch `2.19.7`を3系へ移行する。OpenSearch 3へ進める最低source versionは2.19.0であるためversion条件は満たす。ただしRAGFlow 1.xがOpenSearch 3を正式対応し、[RAGFlowの移行](RAGFLOW.md)が完了するまでは実施してはならない（MUST NOT）。

現在はsingle-node構成のためrolling upgradeではなく、filesystem snapshotを新しいOpenSearch 3 clusterへrestoreする。OpenSearch nodeをdowngradeしてはならない（MUST NOT）。

## Snapshot repositoryの準備

sourceとtargetから同じsnapshotを参照できるよう、`ragflow-opensearch`へ次を追加する。

- bind mount: `/srv/22-ragflow/opensearch-snapshots:/snapshots`
- OpenSearch setting: `path.repo=/snapshots`
- target volume: `ragflow-opensearch-3-data:/usr/share/opensearch/data`

```bash
# snapshot directoryをOpenSearch containerのUID/GIDで作成する。
sudo install -d -o 1000 -g 1000 -m 700 /srv/22-ragflow/opensearch-snapshots

# 更新後のCompose定義を検証する。
sudo docker compose --env-file .env --profile ragflow config --quiet

# repository設定を反映するためOpenSearch 2を再作成する。
sudo docker compose --env-file .env --profile ragflow up -d --wait --force-recreate ragflow-opensearch
```

期待結果:

- OpenSearch 2.19.7がhealthyになり、containerから`/snapshots`へ書き込める。
- 旧`ragflow-opensearch-data` volumeが残る。

失敗条件:

- bind mountのpermission errorが出る。
- cluster healthがyellow以上へ戻らない。

## Source snapshotの作成

```bash
# source clusterのversionとhealthを確認する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" http://127.0.0.1:9201/'
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" "http://127.0.0.1:9201/_cluster/health?wait_for_status=yellow&timeout=30s"'

# source indexごとのdocument数を記録する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" "http://127.0.0.1:9201/_cat/indices?v&h=index,docs.count,store.size"'

# RAGFlowを停止してindexへの書込みを止める。
sudo docker compose --env-file .env --profile ragflow stop ragflow

# transaction logをLucene segmentへflushする。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" -X POST http://127.0.0.1:9201/_flush'

# filesystem snapshot repositoryを登録する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" -H "Content-Type: application/json" -X PUT http://127.0.0.1:9201/_snapshot/ragflow_fs -d '\''{"type":"fs","settings":{"location":"/snapshots","compress":true}}'\'''

# cluster stateと全indexを含むsnapshotを完了まで待って作成する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" -H "Content-Type: application/json" -X PUT "http://127.0.0.1:9201/_snapshot/ragflow_fs/pre-opensearch-3?wait_for_completion=true" -d '\''{"indices":"*","include_global_state":true}'\'''

# snapshotがSUCCESSであることを確認する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" http://127.0.0.1:9201/_snapshot/ragflow_fs/pre-opensearch-3'
```

期待結果:

- sourceが2.19.7、healthがyellow以上である。
- snapshot stateが`SUCCESS`で、failed shardが0件である。

失敗条件:

- snapshot repository verificationまたはsnapshot作成が失敗する。
- RAGFlow停止後もindexへのwriterが残る。

## OpenSearch 3へのRestore

検証済みの3系patch versionへimageを固定し、data volumeを`ragflow-opensearch-3-data`へ変更する。旧2系volumeをtargetへ直接mountしてはならない（MUST NOT）。

```bash
# OpenSearch 2 containerを停止する。
sudo docker compose --env-file .env --profile ragflow stop ragflow-opensearch

# OpenSearch 3だけをempty volumeで起動する。
sudo docker compose --env-file .env --profile ragflow up -d --wait ragflow-opensearch

# target clusterが3系であることを確認する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" http://127.0.0.1:9201/'

# target clusterへfilesystem repositoryを登録する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" -H "Content-Type: application/json" -X PUT http://127.0.0.1:9201/_snapshot/ragflow_fs -d '\''{"type":"fs","settings":{"location":"/snapshots","readonly":true}}'\'''

# security indexを除いてsnapshotをrestoreする。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" -H "Content-Type: application/json" -X POST "http://127.0.0.1:9201/_snapshot/ragflow_fs/pre-opensearch-3/_restore?wait_for_completion=true" -d '\''{"indices":"*,-.opendistro_security","include_global_state":false}'\'''

# index、document、shard状態を確認する。
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" "http://127.0.0.1:9201/_cat/indices?v&h=index,docs.count,store.size"'
sudo docker compose --env-file .env --profile ragflow exec ragflow-opensearch sh -euc 'curl -fsS -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" "http://127.0.0.1:9201/_cluster/health?wait_for_status=yellow&timeout=60s"'

# RAGFlowを起動してretrievalを検証する。
sudo docker compose --env-file .env --profile ragflow up -d --wait ragflow
```

期待結果:

- OpenSearchが3系を報告し、全primary shardが割り当てられる。
- sourceとtargetでindex数とdocument数が一致する。
- RAGFlowの既存document retrievalと新規document parseが成功する。

失敗条件:

- incompatible snapshot、plugin、security index conflictが出る。
- indexまたはdocument数が一致しない。
- RAGFlowがOpenSearch 3のAPIまたはmappingを受け付けない。

## Rollback

RAGFlowを停止し、OpenSearch imageとvolume参照を2.19.7および旧`ragflow-opensearch-data`へ戻す。OpenSearch 3のdata volumeを2系へmountしてはならない（MUST NOT）。

```bash
# RAGFlowとOpenSearch 3を停止する。
sudo docker compose --env-file .env --profile ragflow stop ragflow ragflow-opensearch

# 旧OpenSearch 2 volumeが保持されていることを確認する。
sudo docker volume inspect inferlab_ragflow-opensearch-data >/dev/null
```

旧Compose revisionで2.19.7を起動し、切替後に許可した書込みがある場合はsnapshotから別clusterへ復元して差分を回収する。

## References

- [OpenSearch rolling upgrade](https://docs.opensearch.org/latest/migrate-or-upgrade/rolling-upgrade/)
- [OpenSearch snapshot and restore for migration](https://docs.opensearch.org/latest/migrate-or-upgrade/snapshot-restore/)
- [OpenSearch snapshot API](https://docs.opensearch.org/latest/api-reference/snapshots/index/)
