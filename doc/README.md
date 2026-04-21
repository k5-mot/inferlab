# LLM stack implementation notes

この文書は [DESIGN.md](/workspaces/brainbox/DESIGN.md) を正本として、README と docker-compose 群に落とし込むための運用・実装メモです。仕様判断で迷った場合は DESIGN.md を優先します。

## 1. 設計方針

本 stack はセルフホスト生成 AI 基盤として構成します。

- 推論基盤は **vLLM**。
- 外部公開する LLM API の単一窓口は **LiteLLM**。
- 利用者向け主ポータルは **Open WebUI**。
- AI アプリ構築基盤は **Dify**。
- LLM 呼び出しの observability、評価、プロンプト管理は **Langfuse**。
- コードベース理解は **deepwiki-open**。
- 文書保管・OCR・検索は **Paperless-ngx**。
- 文書生成は **Carbone + Carbone MCP**。
- MCP サーバは原則 Compose 常設運用せず、コーディング支援ツール/コーディングエージェント側で接続する。例外として **Carbone MCP** は Compose 管理対象に含める。
- Compose は layer 単位ではなく、**機能単位**で分割する。
- 外部公開する UI / API は最小限に絞り、それ以外は `llm-internal` に閉じる。
- **n8n は採用しない**。Dify と役割が近く、初期構成で重複するため。
- **会議文字起こし・議事録生成は対象外**。

## 2. 外部公開サービス

| サービス | 外部公開ポート | 公開範囲 / 用途 | 認証・制御方針 |
| --- | ---: | --- | --- |
| Keycloak | `30000/tcp` | アカウント、グループ、OIDC endpoint | OIDC endpoint は到達可能にする。管理コンソールは管理者限定。 |
| Langfuse | `30001/tcp` | LLM observability、評価、プロンプト管理 | Keycloak OIDC。LiteLLM / Dify / Open WebUI の trace 集約先。 |
| Open WebUI | `31001/tcp` | 主ポータル | Keycloak native OIDC。 |
| Dify | `31002/tcp` | AI アプリ構築 | oauth2-proxy 経由。 |
| deepwiki-open | `31003/tcp` | コードベース理解 | oauth2-proxy 経由。 |
| Paperless-ngx | `31004/tcp` | 文書保管・OCR・全文検索 | oauth2-proxy 経由。 |
| Carbone | `31005/tcp` | 文書生成 | oauth2-proxy 経由。Open WebUI / Dify からの利用を主経路にする。 |
| LiteLLM | `40000/tcp` | 外部ツール、IDE、コーディングエージェント向け OpenAI 互換 API | API key / JWT / ネットワーク制限で保護。 |
| Carbone MCP | `51001/tcp` | 文書生成 MCP | oauth2-proxy または同等の認証 gateway 前段。 |

非公開サービスは vLLM 群、Chroma、Docling Serve、Open WebUI Pipelines、Tika、Gotenberg、SearXNG、Postgres、Redis、ClickHouse です。特に vLLM は直接公開せず、外部ツールは LiteLLM だけを使います。

## 3. docker-compose 構成

### 3.1 `docker-compose.common.yml`

IdP、LLM API gateway、推論サービス、media 系を扱う共通基盤です。

| 領域 | サービス | image / build | 備考 |
| --- | --- | --- | --- |
| Identity | `keycloak` | `quay.io/keycloak/keycloak:26.6.1` | `keycloak/realm-export.json` から `worklab` realm を初回 import。 |
| Identity | `postgres-keycloak` | `docker.io/library/postgres:18.3` | Keycloak DB。 |
| AI Gateway | `litellm` | `docker.io/litellm/litellm:v1.83.3-stable` | `litellm/config.yaml` を使用。 |
| Inference | `vllm-gemma4-31b` | `docker.io/vllm/vllm-openai:v0.19.1` | `google/gemma-4-31B-it`。`inference` profile。 |
| Inference | `vllm-qwen3-swallow-32b` | `docker.io/vllm/vllm-openai:v0.19.1` | `tokyotech-llm/Qwen3-Swallow-32B-RL-v0.2`。`inference` profile。 |
| Inference | `vllm-qwen3-coder-30b` | `docker.io/vllm/vllm-openai:v0.19.1` | `Qwen/Qwen3-Coder-30B-A3B-Instruct`。`inference` profile。 |
| Inference | `vllm-harrier-06b` | `docker.io/vllm/vllm-openai:v0.19.1` | `microsoft/harrier-oss-v1-0.6b`。`inference` profile。 |
| Inference | `vllm-harrier-27b` | `docker.io/vllm/vllm-openai:v0.19.1` | `microsoft/harrier-oss-v1-27b`。`inference` profile。 |
| Inference | `vllm-ruri-v3-310m` | `docker.io/vllm/vllm-openai:v0.19.1` | `cl-nagoya/ruri-v3-310m`、embedding。`inference` profile。 |
| Inference | `vllm-qwen3-reranker-06b` | `docker.io/vllm/vllm-openai:v0.19.1` | `Qwen/Qwen3-Reranker-0.6B`、score。`inference` profile。 |
| Inference | `vllm-qwen3-reranker-8b` | `docker.io/vllm/vllm-openai:v0.19.1` | `Qwen/Qwen3-Reranker-8B`、score。`inference` profile。 |
| Inference | `vllm-ruri-v3-reranker-310m` | `docker.io/vllm/vllm-openai:v0.19.1` | `cl-nagoya/ruri-v3-reranker-310m`、score。`inference` profile。 |
| UI / Media | `kokoro-web` | `ghcr.io/eduardolat/kokoro-web:0.1.3` | Open WebUI TTS 用。`media` profile。 |
| UI / Media | `comfyui` | `./comfyui/Dockerfile.cpu` | Open WebUI image generation 用。`media` profile。 |

LiteLLM は `LANGFUSE_PUBLIC_KEY`、`LANGFUSE_SECRET_KEY`、`LANGFUSE_OTEL_HOST` を受け取り、`litellm_settings.callbacks: ["langfuse_otel"]` で gateway-level trace を Langfuse に送ります。

### 3.2 `docker-compose.observability.yml`

| サービス | image | 用途 |
| --- | --- | --- |
| `langfuse` | `docker.io/langfuse/langfuse:3.167.4` | LLM trace、評価、prompt 管理。 |
| `postgres-langfuse` | `docker.io/library/postgres:18.3` | Langfuse metadata DB。 |
| `clickhouse` | `docker.io/clickhouse/clickhouse-server:26.3.3.20` | Langfuse event / analytics store。 |
| `redis-langfuse` | `docker.io/library/redis:8.6.2` | Langfuse queue/cache。 |

Langfuse の適用方針:

| 対象 | 方針 | 備考 |
| --- | --- | --- |
| LiteLLM | 必須 | Proxy 通過分の利用量、レイテンシ、エラーを集約。 |
| Dify | 推奨 | Workflow / Chatflow 単位の app-level trace。 |
| Open WebUI | 推奨 | Pipelines filter pipeline で会話や利用傾向を把握。 |
| コーディング支援ツール | 必須相当 | 直接 Langfuse へつながず、LiteLLM virtual key / user / team / tag で識別。 |
| deepwiki-open | 条件付き | LLM 呼び出し先を LiteLLM に向ければ gateway-level trace を取得可能。 |
| vLLM | 原則不要 | 観測点は LiteLLM。直接呼び例外が出た場合のみ個別計装。 |
| Carbone / Paperless-ngx / SearXNG / Docling Serve | 対象外 | LLM 呼び出し主体ではない。拡張時は LiteLLM 経由に寄せる。 |

LiteLLM と Dify / Open WebUI を同時に Langfuse 連携すると、gateway-level trace と app-level trace の両方に同じ呼び出しが出る可能性があります。初期運用ではコスト・モデル別利用量は LiteLLM、Workflow / 会話デバッグは Dify / Open WebUI と役割分担し、project、tag、session_id で識別します。

### 3.3 `docker-compose.apps.yml`

利用者アプリと oauth2-proxy をまとめます。

| サービス | image | 用途 |
| --- | --- | --- |
| `open-webui` | `ghcr.io/open-webui/open-webui:v0.9.1` | 主ポータル。LiteLLM、Chroma、Docling、SearXNG、Pipelines、Kokoro、ComfyUI を参照。 |
| `dify-api` | `docker.io/langgenius/dify-api:1.10.1` | Dify API。 |
| `dify-worker` | `docker.io/langgenius/dify-api:1.10.1` | Dify worker。 |
| `dify-worker-beat` | `docker.io/langgenius/dify-api:1.10.1` | Dify scheduled worker。 |
| `dify-web` | `docker.io/langgenius/dify-web:1.10.1` | Dify frontend。 |
| `dify-plugin-daemon` | `docker.io/langgenius/dify-plugin-daemon:0.4.1-local` | Dify plugin runtime。 |
| `dify-sandbox` | `docker.io/langgenius/dify-sandbox:0.2.12` | Code execution sandbox。 |
| `dify-db-postgres` | `docker.io/postgres:15-alpine` | Dify DB。`dify/postgres/init-databases.sql` で `dify_plugin` DB も作成。 |
| `dify-redis` | `docker.io/redis:6-alpine` | Dify broker/cache。 |
| `dify-weaviate` | `docker.io/semitechnologies/weaviate:1.27.0` | Dify vector store。 |
| `dify-ssrf-proxy` | `ubuntu/squid:5.2-22.04_beta` | Dify sandbox/plugin 用 SSRF proxy。 |
| `dify` | `nginx:1.29.1` | Dify web/API/plugin の内部 reverse proxy。 |
| `oauth2-proxy-dify` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.2` | Dify external auth gate。 |
| `deepwiki-open` | `ghcr.io/asyncfuncai/deepwiki-open:latest` | コードベース理解。LiteLLM を OpenAI-compatible endpoint として使う。 |
| `oauth2-proxy-deepwiki` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.2` | deepwiki-open external auth gate。 |
| `paperless-ngx` | `ghcr.io/paperless-ngx/paperless-ngx:2.20.14` | 文書保管・OCR・検索。 |
| `paperless-postgres` | `docker.io/postgres:18.3` | Paperless DB。 |
| `paperless-redis` | `docker.io/redis:8.6.2` | Paperless broker/cache。 |
| `paperless-gotenberg` | `docker.io/gotenberg/gotenberg:8` | Office / HTML conversion。 |
| `paperless-tika` | `docker.io/apache/tika:3.3.0.0` | Office text extraction。 |
| `oauth2-proxy-paperless` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.2` | Paperless external auth gate。 |

### 3.4 `docker-compose.knowledge.yml`

RAG、文書解析、検索、文書生成をまとめます。

| サービス | image | 用途 |
| --- | --- | --- |
| `chroma` | `docker.io/chromadb/chroma:1.5.8` | Open WebUI / RAG 用 vector DB。 |
| `open-webui-pipelines` | `ghcr.io/open-webui/pipelines:main` | Langfuse filter や重い前処理向け。 |
| `docling-serve` | `quay.io/docling-project/docling-serve:v1.16.1` | 文書解析 API。 |
| `searxng` | `docker.io/searxng/searxng:2026.4.13-ee66b070a` | Web search backend。 |
| `carbone` | `docker.io/carbone/carbone-ee:full-5.4.5` | 文書生成 engine。 |
| `oauth2-proxy-carbone` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.2` | Carbone external auth gate。 |
| `carbone-mcp` | `docker.io/carbone/carbone-mcp:1.1.1` | 文書生成 MCP。 |
| `oauth2-proxy-carbone-mcp` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.2` | Carbone MCP external auth gate。 |

外部公開は oauth2-proxy 配下の Carbone と Carbone MCP のみです。Chroma、Pipelines、Docling Serve、SearXNG は内部サービスからのみ使います。

## 4. Keycloak bootstrap

`keycloak/realm-export.json` は初回 volume 作成時に import されます。

作成されるもの:

- realm: `worklab`
- groups: `admins`, `builders`, `users`
- clients: `open-webui`, `langfuse`, `dify`, `deepwiki-open`, `paperless-ngx`, `carbone`, `carbone-mcp`
- default client secret: compose の既定 `*_CLIENT_SECRET` と一致
- redirect URI: README の既定 localhost port と一致
- group claim mapper: `groups`

既存 Keycloak volume がある場合、import は再実行されません。realm/client を再生成したい場合は検証環境で volume を削除するか、管理コンソールで手動更新してください。

## 5. アクセス管理グループ

アクセス管理グループは 3 つに絞ります。

| グループ | 用途 |
| --- | --- |
| `admins` | Keycloak、LiteLLM、Langfuse、Dify、deepwiki-open、Paperless-ngx を含む全体管理者。 |
| `builders` | Dify、deepwiki-open、文書生成テンプレート、文書管理高度利用の設計・構築担当。 |
| `users` | Open WebUI、Dify アプリ利用、文書検索・閲覧の一般利用者。 |

## 6. コーディング支援と MCP

コーディング支援・コーディングエージェントは Compose 上の中核サービスとして持ちません。利用者環境から LiteLLM を参照する形を基本とし、バックエンドは `LiteLLM -> vLLM`、主力モデルは `Qwen3-Coder` 系を想定します。

想定ツール:

- Roo Code
- Cline
- Continue
- OpenHands
- OpenCode
- Tabby
- Codex CLI
- Claude Code

MCP サーバは原則として Compose 管理対象に含めません。`filesystem` や `git` のようにアクセス境界が強い MCP は、共通インフラ化せずツール側で閉じる方針です。

想定 MCP:

- `filesystem-mcp`
- `git-mcp`
- `memory-mcp`
- `sequential-thinking-mcp`
- `time-mcp`
- `carbone-mcp`

Compose 管理対象は `carbone-mcp` のみです。

## 7. サービス選定とライセンス整理

| 領域 | 採用 | 保留 / 除外 | ライセンス・注意点 |
| --- | --- | --- | --- |
| LLM 推論基盤 | vLLM | Ollama は保留 | vLLM は Apache-2.0。Ollama は MIT で軽量運用候補だが中核は LiteLLM + vLLM。 |
| LLM Gateway | LiteLLM | なし | OSS 中核は MIT。一部 Enterprise 領域あり。 |
| チャット UI | Open WebUI | AnythingLLM / LibreChat / LobeChat は保留。Hugging Face Chat UI / BionicGPT / Chat Nio は除外 | Open WebUI v0.6.6+ は BSD-3 ベースに branding restriction。大規模利用や rebrand は条件確認。AnythingLLM / LibreChat は MIT。LobeChat は再評価時に一次ソース確認。 |
| コードベース Wiki | deepwiki-open | OpenDeepWiki / CodeWiki / deepwiki-rs は保留 | deepwiki-open は MIT。将来 AsyncReview 側への流れを見て置換余地を残す。 |
| リサーチノート | なし | Open Notebook は除外。Insights LM / SurfSense / KnowNote / Quivr / Khoj / Verba / RAGFlow / PrivateGPT は保留 | 初期要件は Open WebUI + Chroma + Paperless-ngx + Docling で吸収。 |
| Deep Research | なし | OpenDeepResearch は保留 | 後続フェーズ候補。 |
| ノーコード / AI アプリ構築 | Dify | n8n は除外。Flowise / Langflow は保留 | Dify は Apache-2.0 ベース追加条件付き。multi-tenant や frontend branding 改変は商用条件に注意。Flowise は Apache-2.0 と enterprise commercial license が混在し、公開運用は脆弱性報告にも注意。Langflow は再評価時に一次ソース確認。 |
| 文書レビュー・整理 | Paperless-ngx | OpenContracts / Paperless-AI は保留 | Paperless-ngx は GPL-3.0。self-host 利用なら採りやすいが再配布・派生は copyleft 条件に注意。 |
| 文書生成 | Carbone + Carbone MCP | なし | Carbone Docker Edition は無料開始可能だが advanced/enterprise と support は商用条件。Carbone MCP は最終導入前にベンダ条件確認。 |
| RAG / 文書解析 | Chroma, Docling Serve, SearXNG, Open WebUI Pipelines | なし | Chroma は Apache-2.0。Docling Serve と Pipelines は MIT。SearXNG は AGPL-3.0。Pipelines は必要範囲に限定。 |
| 会議文字起こし | なし | OpenTranscribe / Meetily / MeetMemo / Scriberr / Nojoin / Pensieve は保留 | 初期構成では除外。将来はサーバ中心なら OpenTranscribe、ローカル志向なら Meetily / MeetMemo / Scriberr を再評価。 |
| コードレビュー | なし | PR-Agent / OpenReview / Kodus / ai-review は保留 | 初期構成では除外。LiteLLM + vLLM のコーディング支援基盤を先に整える。 |
| チャットツール連携 | なし | Hermes Agent / OpenClaw / AstrBot / CoPaw / HiClaw / Sentient は保留 | 初期構成では除外。OpenClaw は権限設計、AstrBot は AGPL-v3 に注意。 |

## 8. 起動と profile

基本起動:

```bash
COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet
docker compose up -d
```

推論サービス:

```bash
docker compose --profile inference up -d
```

TTS / image generation:

```bash
docker compose --profile media up -d
```

全 profile:

```bash
docker compose --profile inference --profile media up -d
```

`inference` は複数の大規模モデルを同時に起動するため、実機では GPU/VRAM に合わせて対象サービスを絞ってください。例:

```bash
docker compose --profile inference up -d vllm-qwen3-coder-30b litellm
```

## 9. 環境変数

既定値はローカル検証用です。本番では `.env` で必ず上書きしてください。

| 領域 | 主な変数 |
| --- | --- |
| Keycloak | `KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_HOST_PORT`, `KEYCLOAK_HOSTNAME`, `KEYCLOAK_POSTGRES_PASSWORD` |
| LiteLLM | `LITELLM_MASTER_KEY`, `LITELLM_HOST_PORT` |
| Langfuse | `LANGFUSE_HOST_PORT`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_POSTGRES_PASSWORD`, `LANGFUSE_REDIS_PASSWORD`, `CLICKHOUSE_PASSWORD` |
| Open WebUI | `OPEN_WEBUI_HOST_PORT`, `OPEN_WEBUI_URL`, `OPEN_WEBUI_SECRET_KEY`, `OPEN_WEBUI_OAUTH_CLIENT_SECRET`, `OPEN_WEBUI_PIPELINES_API_KEY` |
| Dify | `DIFY_HOST_PORT`, `DIFY_SECRET_KEY`, `DIFY_POSTGRES_PASSWORD`, `DIFY_REDIS_PASSWORD`, `DIFY_WEAVIATE_API_KEY`, `DIFY_SANDBOX_API_KEY`, `DIFY_PLUGIN_DAEMON_KEY`, `DIFY_PLUGIN_DIFY_INNER_API_KEY` |
| oauth2-proxy | `OAUTH2_PROXY_COOKIE_SECRET`, `OAUTH2_PROXY_*_CLIENT_ID`, `OAUTH2_PROXY_*_CLIENT_SECRET`, `OAUTH2_PROXY_*_REDIRECT_URL` |
| Paperless | `PAPERLESS_HOST_PORT`, `PAPERLESS_URL`, `PAPERLESS_SECRET_KEY`, `PAPERLESS_POSTGRES_PASSWORD`, `PAPERLESS_TIME_ZONE`, `PAPERLESS_OCR_LANGUAGE` |
| Carbone | `CARBONE_HOST_PORT`, `CARBONE_MCP_HOST_PORT`, `CARBONE_EE_LICENSE` |
| Media | `KOKORO_WEB_API_KEY` |

`dify/dify.env` と `langfuse/langfuse.env` も compose の環境変数と同じ既定値を使うようにしています。値を変える場合は、DB 側と app 側が同じ値になるよう `.env` にまとめてください。

## 10. 検証

構文と include 解決:

```bash
docker compose config --quiet
docker compose --profile inference --profile media config --quiet
```

サービス一覧:

```bash
docker compose config --services
docker compose --profile inference --profile media config --services
```

dry-run 作成計画:

```bash
docker compose --dry-run create
docker compose --profile inference --profile media --dry-run create
```

実起動後の基本確認:

```bash
docker compose ps
curl -f http://localhost:30000/realms/worklab/.well-known/openid-configuration
curl -f http://localhost:30001/api/public/health
curl -f http://localhost:40000/health
curl -I http://localhost:31001
```

ユーザ側で確認が必要なもの:

- vLLM のモデル取得には Hugging Face への到達性、必要に応じて token、十分な GPU/VRAM が必要です。
- Carbone EE は利用条件と `CARBONE_EE_LICENSE` を確認してください。
- Open WebUI、Langfuse、oauth2-proxy 各 client secret を本番値に変更した場合、Keycloak client secret も同じ値に更新してください。
- 既存 Dify Postgres volume がある環境で `dify_plugin` DB がない場合は、`dify/postgres/init-databases.sql` は自動再実行されません。手動で DB を作成してください。
- image pull 中の `short read` / `unexpected EOF` は、registry 通信が途中で切れた状態です。`COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet` で再開してください。

## 11. 最終構成

この構成の核は次の通りです。

- Open WebUI を主ポータルとする。
- LiteLLM を外部公開する唯一の LLM API とする。
- Langfuse を observability、評価、prompt 管理の集約先とする。
- vLLM を推論基盤の中核とする。
- Dify を AI アプリ構築基盤として採用し、n8n は除外する。
- deepwiki-open をコードベース理解用途で採用する。
- Paperless-ngx を文書保管・OCR・検索基盤として採用する。
- Carbone + Carbone MCP を成果物生成基盤として採用する。
- MCP サーバは原則 Compose 管理対象外とし、Carbone MCP のみ Compose 管理対象に含める。
- アクセス管理グループは `admins` / `builders` / `users` の 3 グループに整理する。

ライセンス上は Open WebUI、Dify、Paperless-ngx、SearXNG、Carbone 系に注意します。Open WebUI は branding 条件、Dify は追加条項付き OSS、Paperless-ngx と SearXNG は copyleft 系、Carbone / Carbone MCP は商用条件確認が必要です。
