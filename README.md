# brainbox

このREADMEを、設計・構成ドキュメントの集約先（SSOT）とします。

## 1. 設計方針

- 推論基盤は **vLLM**、外部公開する OpenAI 互換 API は **LiteLLM** に統一する
- 主ポータルは **Open WebUI**、AI アプリ構築は **Dify** を採用する
- 文書RAG基盤は **RAGFlow** を採用し、通常利用時は **Open WebUI + Pipelines** から呼び出す
- LLM observability は **Langfuse** に集約する
- コード理解は **deepwiki-open**、文書管理は **Paperless-ngx**、文書生成は **Carbone + Carbone MCP** を採用する
- Compose はレイヤではなく機能単位で分割し、公開面を最小化する

## 2. Compose 分割

`docker-compose.yml` は以下を include する。

| Compose                               | 主なサービス                                                                                 |
| ------------------------------------- | -------------------------------------------------------------------------------------------- |
| `docker-compose.common.yml`           | keycloak, postgres-keycloak                                                                  |
| `docker-compose.inference-ollama.yml` | litellm, ollama, ollama-init, inifinity                                                      |
| `docker-compose.inference-vllm.yml`   | litellm, vllm-*                                                                              |
| `docker-compose.openwebui.yml`        | open-webui, qdrant, open-webui-pipelines, docling-serve, searxng, openai-edge-tts, oauth2-proxy-* |
| `docker-compose.ragflow.yml`          | ragflow, ragflow-es01, ragflow-mysql, ragflow-minio, ragflow-redis                            |
| `docker-compose.seafile.yml`          | sync-worker                                                                                   |
| `docker-compose.comfyui.yml`          | comfyui                                                                                      |
| `docker-compose.carbone.yml`          | carbone, carbone-mcp, carbone-gateway                                                        |
| `docker-compose.hermes-agent.yml`     | hermes-agent                                                                                 |
| `docker-compose.openclaw.yml`         | openclaw                                                                                     |
| `docker-compose.dify.yml`             | dify-*                                                                                       |
| `docker-compose.langfuse.yml`         | langfuse, postgres-langfuse, clickhouse, redis-langfuse                                      |
| `docker-compose.paperless.yml`        | paperless-*                                                                                  |
| `docker-compose.deepwiki.yml`         | deepwiki-open                                                                                |
| `docker-compose.nextcloud.yml`        | nextcloud, nextcloud-mariadb, nextcloud-redis, oikb                                          |

## 3. 外部公開ポート

| サービス               | 既定ポート | 備考                     |
| ---------------------- | ---------: | ------------------------ |
| Keycloak               |    `30000` | OIDC / 管理              |
| Langfuse               |    `30001` | observability            |
| Open WebUI             |    `31001` | 主ポータル               |
| Dify                   |    `31002` | oauth2-proxy 経由        |
| deepwiki-open          |    `31003` | oauth2-proxy 経由        |
| Paperless-ngx          |    `31004` | oauth2-proxy 経由        |
| Carbone                |    `31005` | oauth2-proxy 経由        |
| Hermes Agent Gateway   |    `31006` | profile: hermes-agent    |
| Hermes Agent Dashboard |    `31009` | profile: hermes-agent    |
| OpenClaw               |    `31007` | profile: openclaw        |
| RAGFlow                |    `31008` | profile: ragflow         |
| Carbone Gateway        |    `31010` | profile: carbone         |
| Sync Worker            |    `31011` | profile: ragflow/seafile |
| Nextcloud              |    `31012` | profile: nextcloud       |
| OIKB daemon            |    `31013` | Nextcloud -> Open WebUI  |
| LiteLLM                |    `40000` | 外部向け OpenAI 互換 API |
| Carbone MCP            |    `51001` | oauth2-proxy 経由        |

vLLM、Qdrant、Docling、Pipelines、SearXNG、RAGFlow API/DB/Redis/MinIO/Elasticsearch、DB/Redis/ClickHouse は内部のみ。

## 4. 起動

```bash
COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet
docker compose up -d
```

必要時のみ profile を有効化する。Open WebUI は LiteLLM を参照するため、通常は inference 系 profile と一緒に起動する。

```bash
docker compose --profile inference up -d
docker compose --profile media up -d
docker compose --profile inference --profile media up -d
docker compose --profile hermes-agent up -d
docker compose --profile openclaw up -d
docker compose --profile hermes-agent --profile openclaw up -d
```

RAGFlow を Open WebUI のバックエンドとして使う場合は、Open WebUI と RAGFlow を同時に起動する。

```bash
docker compose --profile inference-ollama --profile openwebui --profile ragflow --profile seafile up -d
```

RAGFlow をオフライン環境で起動する前に、tiktoken の `cl100k_base` をオンライン環境で取得しておく。
RAGFlow v0.25.2 は `TIKTOKEN_CACHE_DIR` を `/ragflow` に上書きするため、Compose では tiktoken のキャッシュファイルを `/ragflow` 直下へ bind mount している。
ファイル名は tiktoken が使う `sha1("https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken")` の値に合わせる。

```bash
mkdir -p ragflow
curl -fsSL \
  https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken \
  -o ragflow/9b5ad71b2ce5302211f9c61530b329a4922fc6a4
sha256sum ragflow/9b5ad71b2ce5302211f9c61530b329a4922fc6a4
```

期待する SHA256 は `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7`。

RAGFlow の初期設定は `http://localhost:31008/` で行う。モデルプロバイダは既定で LiteLLM (`http://litellm:4000/v1`) を向くようにしている。RAGFlow 側で Chat または Agent を作成し、API Key と ID を `.env` に設定すると、Open WebUI のモデル一覧に `RAGFlow: Chat: <label>` または `RAGFlow: Agent: <label>` として表示される。

```bash
RAGFLOW_API_KEY=ragflow-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
RAGFLOW_CHAT_IDS=manuals:<chat_id>,policies:<chat_id>
RAGFLOW_AGENT_IDS=research:<agent_id>
RAGFLOW_VISION_MODEL=gemma3:31b
RAGFLOW_TTS_BASE_URL=http://openai-edge-tts:5050/v1
```

RAGFlow の vision 既定モデルは `gemma3:31b@OpenAI`、TTS 既定モデルは `tts-1@OpenAI` として初期化する。TTS の OpenAI 互換 API は `openai-edge-tts` に向ける。

Phase 1 の BookStack / Seafile 同期は `sync-worker` が担当する。
RAGFlow で API Key を作成し、BookStack / Seafile の接続情報と一緒に `.env` へ設定する。

```bash
RAGFLOW_API_KEY=ragflow-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
RAGFLOW_CHAT_ID=
BOOKSTACK_BASE_URL=http://bookstack.example.local
BOOKSTACK_TOKEN_ID=...
BOOKSTACK_TOKEN_SECRET=...
SEAFILE_BASE_URL=http://seafile.example.local
SEAFILE_API_TOKEN=...
SEAFILE_LIBRARY_IDS=
SEAFILE_PATHS=/
```

同期と検索は HTTP API から実行できる。
BookStack は `rag_bookstack`、Seafile は `rag_seafile` データセットに投入し、差分判定は `sync-worker-data` の SQLite state で管理する。

```bash
curl -X POST http://localhost:31011/sync/bookstack
curl -X POST http://localhost:31011/sync/seafile
curl -X POST http://localhost:31011/sync/all

curl -X POST http://localhost:31011/search \
  -H 'Content-Type: application/json' \
  -d '{"question":"VPNの申請手順は？"}'
```

Phase 2 の DOCX/PDF 生成は Carbone Gateway が担当する。
構造化 JSON を Markdown に正規化し、Carbone v5 の `POST /render/template?download=true` で DOCX/PDF に変換する。

```bash
docker compose --profile inference-ollama --profile openwebui --profile ragflow --profile carbone up -d

curl -X POST http://localhost:31010/v1/reports \
  -H 'Content-Type: application/json' \
  -d '{
    "title": "VPN申請手順",
    "summary": "社内VPNの申請から承認までの流れ。",
    "sections": [
      {"title": "手順", "bullets": ["申請フォームを開く", "所属長承認を依頼する"]}
    ],
    "citations": [
      {"ref": 1, "source_name": "IT手順書", "page_url": "http://bookstack.example.local/books/it/page/vpn"}
    ],
    "formats": ["docx", "pdf"]
  }'
```

Open WebUI Pipelines には `RAGFlow: ...` と `Carbone: DOCX/PDF Report` が表示される。
Carbone Pipeline には上記 JSON を貼り付けると、生成された DOCX/PDF のリンクを返す。

Hermes Agent profile を起動すると、gateway に加えて web dashboard も起動する。
既定では `http://127.0.0.1:31009/` で開ける。安全のため Docker 側で localhost のみに公開している。
ポート番号は `HERMES_AGENT_DASHBOARD_HOST_PORT` と `HERMES_AGENT_DASHBOARD_PORT` で調整できる。

Hermes Agent gateway のログに `No user allowlists configured` と出る場合、Telegram/Discord/Slack などのメッセージング経由ユーザーが未許可のため拒否されるという警告である。
メッセージング連携を使う場合は、`.env` などで `HERMES_AGENT_GATEWAY_ALLOWED_USERS` に許可するユーザー ID をカンマ区切りで設定する。
検証用途で全ユーザーを許可したい場合のみ、`HERMES_AGENT_GATEWAY_ALLOW_ALL_USERS=true` を設定する。
API サーバーだけを Open WebUI などから使う場合、この警告は無視できる。

Hermes Agent と OpenClaw の image は環境変数で上書きできる。

```bash
export HERMES_AGENT_IMAGE=ghcr.io/<your-org>/hermes-agent:<tag>
export OPENCLAW_IMAGE=ghcr.io/<your-org>/openclaw:<tag>
docker compose --profile hermes-agent --profile openclaw up -d
```

OpenClaw は公式 Docker 手順に合わせ、config/workspace を named volume に保存する。
`./openclaw/openclaw.json` はユーザー編集用の seed 設定として扱い、初回だけ `inferlab_openclaw-config` に CLI 経由で import する。
初回は `setup.sh` 相当の順番で、所有者補正、必要に応じた onboard、gateway 設定を行う。

```bash
docker compose --profile openclaw run --rm openclaw-permissions
docker compose --profile openclaw run --rm openclaw-init
docker compose --profile openclaw run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js config set --batch-json '[{"path":"gateway.mode","value":"local"},{"path":"gateway.bind","value":"lan"},{"path":"gateway.controlUi.allowedOrigins","value":["http://localhost:31007","http://127.0.0.1:31007","http://192.168.1.100:31007"]}]'
docker compose --profile openclaw up -d openclaw-gateway
```

`./openclaw/openclaw.json` を編集した後、named volume に反映し直す場合は `OPENCLAW_CONFIG_SYNC=always` を付けて seed を再 import する。

```bash
docker compose --profile openclaw run --rm -e OPENCLAW_CONFIG_SYNC=always openclaw-config-import
docker compose --profile openclaw run --rm -e OPENCLAW_CONFIG_SYNC=always openclaw-init
docker compose --profile openclaw up -d --force-recreate openclaw-gateway
```

seed 設定を使わずに OpenClaw の初期設定を生成したい場合は、公式手順と同じく `onboard` を実行する。

```bash
docker compose --profile openclaw run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon
```

OpenClaw の永続データは `inferlab_openclaw-config` と `inferlab_openclaw-workspace` に保存する。
Control UI は `http://127.0.0.1:31007/` または `http://192.168.1.100:31007/` を開き、`./openclaw/openclaw.json` の `gateway.auth.token` か `OPENCLAW_GATEWAY_TOKEN` の値を入力する。
詳細は公式 Docker docs を参照する: https://docs.openclaw.ai/install/docker

## 5. 検証

```bash
docker compose config --quiet
docker compose --profile inference --profile media config --quiet
docker compose config --services
docker compose --profile inference --profile media config --services
```

```bash
docker compose \
  --env-file ./.env.prod \
  --profile common \
  --profile inference-ollama \
  --profile hermes-agent \
  --profile openwebui \
  --profile cloudflare \
  --profile obsidian \
  down --remove-orphans
docker compose \
  --env-file ./.env.prod \
  --profile common \
  --profile inference-ollama \
  --profile hermes-agent \
  --profile openwebui \
  --profile cloudflare \
  --profile obsidian \
  up -d --no-deps --force-recreate --remove-orphans
docker compose \
  --env-file ./.env.prod \
  --profile common \
  --profile inference-ollama \
  --profile hermes-agent \
  --profile openwebui \
  --profile cloudflare \
  --profile obsidian \
  ps

pip3 download -d lib python-docx "docling-mcp[local]" docling Pillow "markitdown[pptx,docx,xlsx,xls,pdf]" markitdown-ocr markitdown-mcp
```
