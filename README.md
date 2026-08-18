# Local AI Stack

## スタック・サービス一覧

### Profile一覧

`dc.sh up` の標準起動に含まれる profile は `common`、`keycloak`、`pubnet`、`inference`、`rag`、`owui`、`nextcloud`、`obsidian`、`o11y`、`langfuse` です。`registry`、`dify`、`bookstack`、`kaneo`、`zulip`、`gitlab` などのその他の profile は必要な場合に個別に指定します。

| Profile | Compose file | 用途 |
| --- | --- | --- |
| `common` | `00-common/docker-compose.yml` | 共通入口と疎通確認 |
| `keycloak` | `01-keycloak/docker-compose.yml` | 認証 |
| `pubnet` | `02-pubnet/docker-compose.yml` | 外部公開ネットワーク |
| `inference` | `10-inference/docker-compose.yml` | 推論、埋め込み、エージェント、音声合成 |
| `rag` | `11-rag/docker-compose.yml` | 文書処理とベクトル検索 |
| `registry` | `12-registry/docker-compose.yml` | 開発用パッケージ配布 |
| `owui` | `20-owui/docker-compose.yml` | Open WebUI、検索、ツール連携、Knowledge同期 |
| `dify` | `21-dify/docker-compose.yml` | 自動化 |
| `nextcloud` | `30-nextcloud/docker-compose.yml` | ファイル保存 |
| `bookstack` | `31-bookstack/docker-compose.yml` | Wiki |
| `kaneo` | `32-kaneo/docker-compose.yml` | プロジェクト管理 |
| `zulip` | `33-zulip/docker-compose.yml` | チャット |
| `gitlab` | `34-gitlab/docker-compose.yml` | Git 管理とCI |
| `obsidian` | `40-obsidian/docker-compose.yml` | Obsidian同期用CouchDB |
| `o11y` | `50-o11y/docker-compose.yml` | 監視 |
| `langfuse` | `51-langfuse/docker-compose.yml` | Langfuse |

### Service一覧

ルートの `docker-compose.yml` が include する Compose ファイルに定義された有効な service は次のとおりです。`Port` が `-` の service は host へ公開していません。

| Profile | Service | Port | Compose file |
| --- | --- | --- | --- |
| `common` | `homepage` | `30000` | `00-common/docker-compose.yml` |
| `common` | `whoami` | `30003` | `00-common/docker-compose.yml` |
| `keycloak` | `keycloak` | `30001` | `01-keycloak/docker-compose.yml` |
| `keycloak` | `keycloak-https` | `30002` | `01-keycloak/docker-compose.yml` |
| `keycloak` | `keycloak-postgres` | - | `01-keycloak/docker-compose.yml` |
| `pubnet` | `cloudflare` | - | `02-pubnet/docker-compose.yml` |
| `inference` | `litellm` | `31000` | `10-inference/docker-compose.yml` |
| `inference` | `ollama` | - | `10-inference/docker-compose.yml` |
| `inference` | `ollama-init` | - | `10-inference/docker-compose.yml` |
| `inference` | `tei-embedding` | - | `10-inference/docker-compose.yml` |
| `inference` | `tei-reranking` | - | `10-inference/docker-compose.yml` |
| `inference`, `hermes-agent` | `hermes-agent` | `31001` | `10-inference/docker-compose.yml` |
| `inference`, `hermes-agent` | `openclaw` | `31002` | `10-inference/docker-compose.yml` |
| `inference` | `kokoro` | `31005` | `10-inference/docker-compose.yml` |
| `rag` | `docling` | `31100` | `11-rag/docker-compose.yml` |
| `rag` | `qdrant` | - | `11-rag/docker-compose.yml` |
| `registry` | `pypiserver` | `31200` | `12-registry/docker-compose.yml` |
| `registry` | `verdaccio` | `31201` | `12-registry/docker-compose.yml` |
| `registry` | `code-marketplace` | `31202` | `12-registry/docker-compose.yml` |
| `registry` | `code-marketplace-importer` | - | `12-registry/docker-compose.yml` |
| `registry` | `npm-importer` | - | `12-registry/docker-compose.yml` |
| `registry` | `createrepo_c` | - | `12-registry/docker-compose.yml` |
| `registry` | `rpm-dist` | `31203` | `12-registry/docker-compose.yml` |
| `registry` | `reprepro` | - | `12-registry/docker-compose.yml` |
| `registry` | `deb-dist` | `31204` | `12-registry/docker-compose.yml` |
| `registry` | `docker-registry` | `31205` | `12-registry/docker-compose.yml` |
| `owui` | `open-webui` | `32000` | `20-owui/docker-compose.yml` |
| `owui` | `open-terminal` | `32003` | `20-owui/docker-compose.yml` |
| `owui` | `mcpo` | `32004` | `20-owui/docker-compose.yml` |
| `owui` | `searxng` | `32002` | `20-owui/docker-compose.yml` |
| `owui` | `oikb-rustfs` | `32005`, `32006` | `20-owui/docker-compose.yml` |
| `owui` | `oikb-rustfs-bucket-init` | - | `20-owui/docker-compose.yml` |
| `owui` | `oikb` | `32001` | `20-owui/docker-compose.yml` |
| `dify` | `dify-init-permissions` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-api` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-worker` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-worker-beat` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-web` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-plugin-daemon` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-sandbox` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-local-sandbox` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-agent-backend` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-ssrf-proxy` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-postgres` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-postgres-init` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-redis` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-qdrant` | - | `21-dify/docker-compose.yml` |
| `dify` | `dify-nginx` | `32100` | `21-dify/docker-compose.yml` |
| `nextcloud` | `nextcloud` | `33000` | `30-nextcloud/docker-compose.yml` |
| `nextcloud` | `nextcloud-postgres` | - | `30-nextcloud/docker-compose.yml` |
| `nextcloud` | `nextcloud-valkey` | - | `30-nextcloud/docker-compose.yml` |
| `bookstack` | `bookstack` | `33100` | `31-bookstack/docker-compose.yml` |
| `bookstack` | `bookstack-custom-init` | - | `31-bookstack/docker-compose.yml` |
| `bookstack` | `bookstack-mariadb` | - | `31-bookstack/docker-compose.yml` |
| `kaneo` | `kaneo` | `33200` | `32-kaneo/docker-compose.yml` |
| `kaneo` | `kaneo-postgres` | - | `32-kaneo/docker-compose.yml` |
| `zulip` | `zulip` | `33302`, `33300`, `33325` | `33-zulip/docker-compose.yml` |
| `zulip` | `zulip-postgres` | - | `33-zulip/docker-compose.yml` |
| `zulip` | `zulip-memcached` | - | `33-zulip/docker-compose.yml` |
| `zulip` | `zulip-rabbitmq` | - | `33-zulip/docker-compose.yml` |
| `zulip` | `zulip-redis` | - | `33-zulip/docker-compose.yml` |
| `gitlab` | `gitlab` | `33400`, `33422` | `34-gitlab/docker-compose.yml` |
| `gitlab` | `gitlab-runner-register` | - | `34-gitlab/docker-compose.yml` |
| `gitlab` | `gitlab-runner` | - | `34-gitlab/docker-compose.yml` |
| `obsidian` | `couchdb` | `34000` | `40-obsidian/docker-compose.yml` |
| `o11y` | `grafana` | `35000` | `50-o11y/docker-compose.yml` |
| `o11y` | `prometheus` | `35001` | `50-o11y/docker-compose.yml` |
| `o11y` | `node-exporter` | - | `50-o11y/docker-compose.yml` |
| `o11y` | `cadvisor` | - | `50-o11y/docker-compose.yml` |
| `o11y` | `blackbox-exporter` | - | `50-o11y/docker-compose.yml` |
| `langfuse` | `langfuse-worker` | - | `51-langfuse/docker-compose.yml` |
| `langfuse` | `langfuse-web` | `35100` | `51-langfuse/docker-compose.yml` |
| `langfuse` | `langfuse-clickhouse` | - | `51-langfuse/docker-compose.yml` |
| `langfuse` | `langfuse-valkey` | - | `51-langfuse/docker-compose.yml` |
| `langfuse` | `langfuse-rustfs` | `35102`, `35103` | `51-langfuse/docker-compose.yml` |
| `langfuse` | `langfuse-rustfs-bucket-init` | - | `51-langfuse/docker-compose.yml` |
| `langfuse` | `langfuse-postgres` | - | `51-langfuse/docker-compose.yml` |

## ドキュメント目次

### 利用手順

- [初期設定](docs/manual/INITIAL_SETUP.md)
- [テスト](docs/manual/TEST.md)
- [オフライン用資材のダウンロード](docs/manual/DOWNLOAD.md)
- [Registry利用ガイド](docs/manual/REGISTRY.md)
- [構成図](docs/assets/DIAGRAM.svg)

### 開発ルール

- [コーディングルール](docs/rules/CODING_RULES.md)
- [コントリビューションルール](docs/rules/CONTRIBUTING.md)

### トラブルシューティング

- [OpenWebUIファイル取込時のDocling負荷](docs/troubleshooting/OPENWEBUI_DOCLING_LOAD.md)
- [TEI起動時のホストresource枯渇](docs/troubleshooting/TEI_RESOURCE_EXHAUSTION.md)

### スタック別ガイド

- [Keycloak](01-keycloak/README.md)
- [Inference](10-inference/README.md)
- [RAG](11-rag/README.md)
- [Registry](12-registry/README.md)
- [Open WebUI](20-owui/README.md)
- [Dify](21-dify/README.md)
- [Nextcloud](30-nextcloud/README.md)
- [BookStack](31-bookstack/README.md)
- [Zulip](33-zulip/README.md)
- [GitLab](34-gitlab/README.md)
- [Observability](50-o11y/README.md)
- [Langfuse](51-langfuse/README.md)

## Author

[k5-mot](https://github.com/k5-mot)

## License

プロジェクト全体を対象とするライセンスは設定されていません。サードパーティー素材には、各配置先に記載されたライセンスが適用されます。

## LiteLLM動作確認

```bash
# LiteLLM gateway経由でchat completions APIの応答を確認する。
curl -fsS -X POST 'http://localhost:31000/chat/completions' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-litellm-master-key' \
  -d '{
    "model": "google/gemma4:31b",
    "messages": [
      {
        "role": "user",
        "content": "相模原市の特産品は？"
      }
    ]
  }'
```
