# brainbox

このリポジトリは、セルフホスト生成 AI 基盤の standalone stack です。
設計書の正本は [DESIGN.md](/workspaces/brainbox/DESIGN.md) で、運用・実装向けの展開版は [doc/README.md](/workspaces/brainbox/doc/README.md) です。

## 設計の要点

- 推論基盤は **vLLM**、外部公開する OpenAI 互換 LLM API は **LiteLLM** に一本化する。
- 利用者向け主ポータルは **Open WebUI**、AI アプリ構築は **Dify** とする。
- LLM observability、評価、プロンプト管理は **Langfuse** に集約し、LiteLLM は `langfuse_otel` callback を有効化する。
- コードベース理解は **deepwiki-open**、文書保管・OCR・検索は **Paperless-ngx**、文書生成は **Carbone + Carbone MCP** を採用する。
- MCP サーバは原則 Compose 常設に含めず、コーディング支援ツール側で接続する。例外として Carbone MCP のみ Compose 管理対象に含める。
- Compose は layer ではなく機能単位で分割し、外部公開する UI / API を最小限にする。
- **n8n、会議文字起こし、PR レビュー自動化、チャットツール常駐 bot は初期構成から除外**する。

## Compose 構成

| Compose                            | 主なサービス                                                               |
| ---------------------------------- | -------------------------------------------------------------------------- |
| `docker-compose.common.yml`        | Keycloak, LiteLLM, vLLM 群, Kokoro Web, ComfyUI                            |
| `docker-compose.observability.yml` | Langfuse, Postgres, ClickHouse, Redis                                      |
| `docker-compose.apps.yml`          | Open WebUI, Dify, deepwiki-open, Paperless-ngx, oauth2-proxy               |
| `docker-compose.knowledge.yml`     | Chroma, Open WebUI Pipelines, Docling Serve, SearXNG, Carbone, Carbone MCP |
| `docker-compose.yml`               | 上記 compose 群の統合入口                                                  |

## 外部公開ポート

| サービス      | 既定ポート | 用途                                       |
| ------------- | ---------: | ------------------------------------------ |
| Keycloak      |    `30000` | OIDC endpoint / 管理者向け管理コンソール   |
| Langfuse      |    `30001` | LLM observability / 評価 / prompt 管理     |
| Open WebUI    |    `31001` | 利用者向け主ポータル                       |
| Dify          |    `31002` | AI アプリ構築、oauth2-proxy 経由           |
| deepwiki-open |    `31003` | コードベース理解、oauth2-proxy 経由        |
| Paperless-ngx |    `31004` | 文書保管・OCR・全文検索、oauth2-proxy 経由 |
| Carbone       |    `31005` | 文書生成、oauth2-proxy 経由                |
| LiteLLM       |    `40000` | 外部ツール向け OpenAI 互換 API             |
| Carbone MCP   |    `51001` | 文書生成 MCP、oauth2-proxy 経由            |

vLLM、Chroma、Docling Serve、Open WebUI Pipelines、Tika、Gotenberg、SearXNG、DB/Redis/ClickHouse は外部公開しません。

## 起動

大容量 image が多いため、初回は並列 pull を抑えて先に取得しておくと安定します。

```bash
COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet
```

```bash
docker compose up -d
```

vLLM 推論サーバと media 系は重いため profile で明示起動します。

```bash
docker compose --profile inference up -d
docker compose --profile media up -d
docker compose --profile inference --profile media up -d
```

初回起動時、Keycloak は `keycloak/realm-export.json` から `worklab` realm、OIDC client、`admins` / `builders` / `users` グループを import します。既に Keycloak volume が初期化済みの場合、import は再適用されないため、realm/client の変更は Keycloak 管理コンソールで反映してください。

## 設定

既定値はローカル検証向けです。本番・共有環境では少なくとも次を `.env` で上書きしてください。

- `KEYCLOAK_ADMIN_PASSWORD`
- `KEYCLOAK_POSTGRES_PASSWORD`
- `LITELLM_MASTER_KEY`
- `LANGFUSE_PUBLIC_KEY`
- `LANGFUSE_SECRET_KEY`
- `LANGFUSE_POSTGRES_PASSWORD`
- `LANGFUSE_REDIS_PASSWORD`
- `CLICKHOUSE_PASSWORD`
- `OPEN_WEBUI_SECRET_KEY`
- `DIFY_SECRET_KEY`
- `DIFY_POSTGRES_PASSWORD`
- `DIFY_REDIS_PASSWORD`
- `PAPERLESS_SECRET_KEY`
- `PAPERLESS_POSTGRES_PASSWORD`
- `OAUTH2_PROXY_COOKIE_SECRET`
- `*_CLIENT_SECRET`

## 検証

```bash
docker compose config --quiet
docker compose --profile inference --profile media config --quiet
docker compose config --services
docker compose --profile inference --profile media config --services
```

起動後の確認:

```bash
docker compose ps
curl -f http://localhost:30000/realms/worklab/.well-known/openid-configuration
curl -f http://localhost:40000/health
```

GPU、モデル取得、Carbone EE ライセンス、Keycloak の本番用 client secret などは環境依存です。実機検証の詳細は [doc/README.md](/workspaces/brainbox/doc/README.md) を参照してください。

`short read` / `unexpected EOF` が pull 中に出た場合は、registry 通信が途中で切れています。compose 定義エラーではないため、次で再開してください。

```bash
COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet
COMPOSE_PARALLEL_LIMIT=1 docker compose up -d
```
