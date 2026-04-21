# brainbox

このREADMEを、設計・構成ドキュメントの集約先（SSOT）とします。

## 1. 設計方針

- 推論基盤は **vLLM**、外部公開する OpenAI 互換 API は **LiteLLM** に統一する
- 主ポータルは **Open WebUI**、AI アプリ構築は **Dify** を採用する
- LLM observability は **Langfuse** に集約する
- コード理解は **deepwiki-open**、文書管理は **Paperless-ngx**、文書生成は **Carbone + Carbone MCP** を採用する
- Compose はレイヤではなく機能単位で分割し、公開面を最小化する

## 2. Compose 分割

`docker-compose.yml` は以下を include する。

| Compose | 主なサービス |
| --- | --- |
| `docker-compose.common.yml` | keycloak, postgres-keycloak |
| `docker-compose.inference.yml` | litellm, vllm-* |
| `docker-compose.openwebui.yml` | open-webui, kokoro-web, chroma, open-webui-pipelines, docling-serve, searxng, oauth2-proxy-* |
| `docker-compose.comfyui.yml` | comfyui |
| `docker-compose.carbone.yml` | carbone, carbone-mcp |
| `docker-compose.dify.yml` | dify-* |
| `docker-compose.langfuse.yml` | langfuse, postgres-langfuse, clickhouse, redis-langfuse |
| `docker-compose.paperless.yml` | paperless-* |
| `docker-compose.deepwiki.yml` | deepwiki-open |

## 3. 外部公開ポート

| サービス | 既定ポート | 備考 |
| --- | ---: | --- |
| Keycloak | `30000` | OIDC / 管理 |
| Langfuse | `30001` | observability |
| Open WebUI | `31001` | 主ポータル |
| Dify | `31002` | oauth2-proxy 経由 |
| deepwiki-open | `31003` | oauth2-proxy 経由 |
| Paperless-ngx | `31004` | oauth2-proxy 経由 |
| Carbone | `31005` | oauth2-proxy 経由 |
| LiteLLM | `40000` | 外部向け OpenAI 互換 API |
| Carbone MCP | `51001` | oauth2-proxy 経由 |

vLLM、Chroma、Docling、Pipelines、SearXNG、DB/Redis/ClickHouse は内部のみ。

## 4. 起動

```bash
COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet
docker compose up -d
```

必要時のみ profile を有効化する。

```bash
docker compose --profile inference up -d
docker compose --profile media up -d
docker compose --profile inference --profile media up -d
```

## 5. 検証

```bash
docker compose config --quiet
docker compose --profile inference --profile media config --quiet
docker compose config --services
docker compose --profile inference --profile media config --services
```
