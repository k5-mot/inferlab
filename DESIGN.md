
# 設計書改訂版

## 1. 設計方針

本構成は、セルフホスト生成AI基盤として、以下の方針で設計する。

- 推論基盤は **vLLM** を中核とする
- 外部公開する LLM API の単一窓口は **LiteLLM** とする
- 利用者向け主ポータルは **Open WebUI** とする
- AI アプリ構築基盤は **Dify** を採用する
- LLM 呼び出しの observability、評価、プロンプト管理は **Langfuse** に集約する
- コードベース理解は **deepwiki-open** を採用する
- 文書保管・OCR・検索は **Paperless-ngx** を採用する
- 文書生成は **Carbone + Carbone MCP** を採用する
- MCP サーバは原則 Compose 常設運用せず、**コーディング支援ツール/コーディングエージェント側のツール連携として使う**。ただし **Carbone MCP** は文書生成基盤の公式 companion として Compose 管理対象に含める。
- Compose は layer 単位ではなく、**機能単位**で分割する
- 外部公開する UI / API は最小限に絞り、その他は内部ネットワークに閉じる。

今回の設計では、**n8n は採用しない**。理由は Dify と役割が近く、初期構成での重複を避けるためである。
また、**会議文字起こし・議事録生成は今回の対象外**とする。

---

## 2. 外部公開する主要サービスとポート

外部公開対象は、利用者または外部ツールから直接到達が必要なものに限定する。

|サービス|外部公開ポート|公開範囲 / 用途|認証・制御方針|
|---|---|---|---|
|Keycloak|`30000/tcp`|アカウント作成、削除、OIDC 用エンドポイント|OIDC エンドポイントはリバースプロキシ越しに到達可能とする。管理コンソールは管理者限定とし、常時一般公開しない。|
|Langfuse|`30001/tcp`|LLM observability、評価、プロンプト管理|Keycloak ネイティブ OIDC。LiteLLM / Dify / Open WebUI の LLM トレース集約先とする。|
|Open WebUI|`31001/tcp`|主ポータル|Keycloak ネイティブ OIDC を優先する。|
|Dify|`31002/tcp`|AI アプリ構築|oauth2-proxy 経由。|
|deepwiki-open|`31003/tcp`|コードベース理解|oauth2-proxy 経由。|
|Paperless-ngx|`31004/tcp`|文書保管・OCR・全文検索|oauth2-proxy 経由。|
|Carbone|`31005/tcp`|文書作成|oauth2-proxy 経由。Open WebUI / Dify からの利用を主経路とし、必要に応じてネットワーク制限を加える。|
|LiteLLM|`40000/tcp`|外部ツール、IDE、コーディングエージェント向け OpenAI 互換 API|API key / JWT / ネットワーク制限で保護する。|
|Carbone MCP|`51001/tcp`|文書作成 MCP|oauth2-proxy または同等の認証ゲートウェイを前段に置き、利用元を制限する。|

Keycloak と Langfuse はそれぞれ独立した外部公開ポートで運用する。Keycloak は IdP として OIDC 用エンドポイントを公開対象に含めるが、管理コンソールは管理者限定とし、一般利用者向け UI として常時公開しない。

**非公開**とする主なサービスは、Keycloak 管理 UI、各 vLLM、Chroma、Docling Serve、Open WebUI Pipelines、Tika、Gotenberg、SearXNG、DB/Redis/ClickHouse である。
特に **vLLM は直接公開せず、LiteLLM のみを公開**する。これにより、コーディング支援ツールや将来のエージェント系ツールは共通入口として LiteLLM を利用できる。

---

## 3. docker-compose構成

### 3.1 `docker-compose.common.yml`

従来の identity compose と ai-platform compose を統合した、共通基盤 compose とする。
IdP、LLM API ゲートウェイ、推論サービスを同じライフサイクルで扱い、Open WebUI、Dify、外部ツールが参照する基盤サービスをここに集約する。

含めるサービスと固定イメージは以下とする。

|領域|サービス|image|参照 / 備考|
|---|---|---|---|
|Identity|`keycloak`|`quay.io/keycloak/keycloak:26.6.1`|[Keycloak](https://www.keycloak.org/getting-started/getting-started-docker "https://www.keycloak.org/getting-started/getting-started-docker")|
|Identity|`postgres-keycloak`|`docker.io/library/postgres:18.3`|[Docker Hub](https://hub.docker.com/_/postgres?tab=tags "https://hub.docker.com/_/postgres?tab=tags") / [Keycloak DB](https://www.keycloak.org/server/db)|
|AI Gateway|`litellm`|`docker.io/litellm/litellm:v1.83.3-stable`|[Docker Hub](https://hub.docker.com/r/litellm/litellm/tags "https://hub.docker.com/r/litellm/litellm/tags")|
|Inference|`vllm-gemma4-31b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/google/gemma-4-31B-it)|
|Inference|`vllm-qwen3-swallow-32b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/tokyotech-llm/Qwen3-Swallow-32B-RL-v0.2)|
|Inference|`vllm-qwen3-coder-30b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct)|
|Inference|`vllm-harrier-06b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/microsoft/harrier-oss-v1-0.6b)|
|Inference|`vllm-harrier-27b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/microsoft/harrier-oss-v1-27b)|
|Inference|`vllm-ruri-v3-310m`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/cl-nagoya/ruri-v3-310m)|
|Inference|`vllm-qwen3-reranker-06b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B)|
|Inference|`vllm-qwen3-reranker-8b`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/Qwen/Qwen3-Reranker-8B)|
|Inference|`vllm-ruri-v3-reranker-310m`|`docker.io/vllm/vllm-openai:v0.19.1`|[Docker Hub v0.19.1](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.19.1) / [HuggingFace](https://huggingface.co/cl-nagoya/ruri-v3-reranker-310m)|
|UI / Media|`kokoro-web`|`ghcr.io/eduardolat/kokoro-web:0.1.3`|[GitHub](https://github.com/eduardolat/kokoro-web) / [GitHub Registry](https://github.com/eduardolat/kokoro-web/pkgs/container/kokoro-web)|
|UI / Media|`comfyui`|`未定`|[GitHub](https://github.com/Comfy-Org/ComfyUI) / 専用イメージがないため Dockerfile を作成する。|

役割は IdP、ユーザー管理、グループ管理、OIDC クライアント管理、LLM API 集約、推論基盤。
Keycloak の公式コンテナは Quay で公開されており、公式ガイドは `quay.io/keycloak/keycloak:26.6.1` を例示している。LiteLLM は upstream が **stable tag の使用を推奨**しており、vLLM は公式に Docker Hub の `vllm/vllm-openai` を案内している。
本構成では **Keycloak と LiteLLM を外部公開**し、**vLLM 群は内部専用**とする。コーディング支援・コーディングエージェントは LiteLLM を共通入口として利用する。
LiteLLM は Langfuse への observability 連携を必須とし、`LANGFUSE_PUBLIC_KEY`、`LANGFUSE_SECRET_KEY`、`LANGFUSE_OTEL_HOST` を設定した上で `litellm_settings.callbacks: ["langfuse_otel"]` を有効化する。これにより LiteLLM Proxy を通過する LLM 呼び出しを Langfuse に集約する。 ([Keycloak](https://www.keycloak.org/server/containers "https://www.keycloak.org/server/containers")) ([GitHub](https://github.com/BerriAI/litellm "https://github.com/BerriAI/litellm")) ([Langfuse](https://langfuse.com/integrations/gateways/litellm "https://langfuse.com/integrations/gateways/litellm"))

---

### 3.2 `docker-compose.observability.yml`

含めるサービスと固定イメージは以下とする。

|サービス|image|参照 / 備考|
|---|---|---|
|`langfuse`|`docker.io/langfuse/langfuse:3.167.4`|[Docker Hub](https://hub.docker.com/r/langfuse/langfuse/tags "https://hub.docker.com/r/langfuse/langfuse/tags")|
|`postgres-langfuse`|`docker.io/library/postgres:18.3`|[Docker Hub](https://hub.docker.com/_/postgres?tab=tags "https://hub.docker.com/_/postgres?tab=tags")|
|`clickhouse`|`docker.io/clickhouse/clickhouse-server:26.3.3.20`|[Docker Hub](https://hub.docker.com/r/clickhouse/clickhouse-server/tags "https://hub.docker.com/r/clickhouse/clickhouse-server/tags")|
|`redis-langfuse`|`docker.io/library/redis:8.6.2`|[Docker Hub](https://hub.docker.com/_/redis "https://hub.docker.com/_/redis")|

Langfuse は self-host 時に Postgres、ClickHouse、Redis/Valkey を前提にしており、ClickHouse は `>=24.3` が必要とされる。Langfuse 自体は OSS 部分が MIT ベースで、Enterprise 機能は別ライセンスで追加される。 ([Langfuse](https://langfuse.com/self-hosting "https://langfuse.com/self-hosting"))

Langfuse の適用対象は以下とする。

|対象|方針|理由 / 備考|
|---|---|---|
|LiteLLM|必須|LiteLLM Proxy の `langfuse_otel` callback で、プロキシを通る全 LLM 呼び出し、利用量、レイテンシ、エラーを集約する。|
|Dify|推奨|Dify 公式の Langfuse 連携で Workflow / Chatflow、メッセージ、ツール、検索、モデレーション等のアプリ単位トレースを取得できる。|
|Open WebUI|推奨|Open WebUI Pipelines の Langfuse filter pipeline で、Open WebUI の会話、利用傾向、ユーザー / モデル別コスト、評価に使うトレースを取得できる。|
|コーディング支援ツール / コーディングエージェント|必須相当|Roo Code、Cline、Continue、Codex CLI 等は直接 Langfuse に接続せず、LiteLLM 経由で一元的にトレースする。LiteLLM virtual key、user、team、tag を使って利用元を識別する。|
|deepwiki-open|条件付き|LLM 呼び出し先を LiteLLM に向ける場合は、LiteLLM 側で gateway-level trace を取得できる。アプリ内部の詳細トレースは公式連携の有無を再評価時に確認する。|
|vLLM|原則不要|vLLM は内部推論サーバとして直接公開しないため、観測点は LiteLLM に置く。vLLM を LiteLLM 経由せず直接呼ぶ例外が出た場合のみ、Langfuse SDK / OpenTelemetry で個別計装する。|
|Carbone / Paperless-ngx / SearXNG / Docling Serve|対象外|通常の LLM 呼び出し主体ではないため Langfuse の主対象外とする。LLM を呼ぶ拡張を追加する場合は LiteLLM 経由に寄せて観測する。|

LiteLLM、Dify、Open WebUI を同時に Langfuse 連携すると、同じ LLM 呼び出しが gateway-level trace と app-level trace の両方に現れる可能性がある。初期運用では、コスト・レイテンシ・モデル別利用量は LiteLLM、アプリ上の会話・Workflow デバッグは Dify / Open WebUI という役割分担にし、Langfuse project、tag、session_id で識別する。 ([Dify Docs](https://docs.dify.ai/en/use-dify/monitor/integrations/integrate-langfuse "https://docs.dify.ai/en/use-dify/monitor/integrations/integrate-langfuse")) ([Open WebUI](https://docs.openwebui.com/tutorials/integrations/langfuse/ "https://docs.openwebui.com/tutorials/integrations/langfuse/")) ([Langfuse](https://langfuse.com/integrations "https://langfuse.com/integrations"))

---

### 3.3 `docker-compose.apps.yml`

従来の user-apps compose と auth-proxy compose を統合した compose とする。

含めるサービスと固定イメージは以下とする。

|サービス|image|参照 / 備考|
|---|---|---|
|`open-webui`|`ghcr.io/open-webui/open-webui:v0.9.1`|[Open WebUI](https://docs.openwebui.com/enterprise/deployment/container-service/ "https://docs.openwebui.com/enterprise/deployment/container-service/")。本番では `v0.x.x` の versioned tag 利用を推奨。|
|`dify-api`|`docker.io/langgenius/dify-api:1.10.1`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-worker`|`docker.io/langgenius/dify-api:1.10.1`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-worker-beat`|`docker.io/langgenius/dify-api:1.10.1`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-web`|`docker.io/langgenius/dify-web:1.10.1`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-plugin-daemon`|`docker.io/langgenius/dify-plugin-daemon:0.4.1-local`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-sandbox`|`docker.io/langgenius/dify-sandbox:0.2.12`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-db-postgres`|`docker.io/postgres:15-alpine`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-redis`|`docker.io/redis:6-alpine`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`dify-weaviate`|`docker.io/semitechnologies/weaviate:1.27.0`|[Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose")|
|`oauth2-proxy-dify`|`quay.io/oauth2-proxy/oauth2-proxy:v7.15.2`|[GitHub](https://github.com/oauth2-proxy/oauth2-proxy "https://github.com/oauth2-proxy/oauth2-proxy")|
|`deepwiki-open`|`ghcr.io/asyncfuncai/deepwiki-open:latest`|[GitHub](https://github.com/AsyncFuncAI/deepwiki-open "https://github.com/AsyncFuncAI/deepwiki-open")|
|`oauth2-proxy-deepwiki`|`quay.io/oauth2-proxy/oauth2-proxy:v7.15.2`|[GitHub](https://github.com/oauth2-proxy/oauth2-proxy "https://github.com/oauth2-proxy/oauth2-proxy")|
|`paperless-ngx`|`ghcr.io/paperless-ngx/paperless-ngx:2.20.14`|[GitHub](https://github.com/paperless-ngx/paperless-ngx "https://github.com/paperless-ngx/paperless-ngx")|
|`paperless-postgres`|`docker.io/postgres:18.3`|[Docker Hub](https://hub.docker.com/_/postgres?tab=tags "https://hub.docker.com/_/postgres?tab=tags")|
|`paperless-redis`|`docker.io/redis:8.6.2`|[Docker Hub](https://hub.docker.com/_/redis "https://hub.docker.com/_/redis")|
|`paperless-gotenberg`|`docker.io/gotenberg/gotenberg:8`|[Docker Hub](https://hub.docker.com/r/gotenberg/gotenberg/ "https://hub.docker.com/r/gotenberg/gotenberg/")|
|`paperless-tika`|`docker.io/apache/tika:3.3.0.0`|[Docker Hub](https://hub.docker.com/r/apache/tika/tags "https://hub.docker.com/r/apache/tika/tags")|
|`oauth2-proxy-paperless`|`quay.io/oauth2-proxy/oauth2-proxy:v7.15.2`|[GitHub](https://github.com/oauth2-proxy/oauth2-proxy "https://github.com/oauth2-proxy/oauth2-proxy")|

Dify は upstream の self-host compose で **5つのコアサービス**と依存コンポーネントを前提にしており、`api/web/worker/worker_beat/plugin_daemon` を分けて扱うのが自然である。
deepwiki-open は公式 README で `ghcr.io/asyncfuncai/deepwiki-open:latest` を案内している。Paperless-ngx は公式に GHCR 配布と compose 導入を案内し、Office 解析のために Tika と Gotenberg を追加可能としている。 ([Dify Docs](https://docs.dify.ai/getting-started/install-self-hosted/docker-compose "https://docs.dify.ai/getting-started/install-self-hosted/docker-compose"))

---

### 3.4 `docker-compose.knowledge.yml`

従来の rag-docproc compose と docgen compose を統合した compose とする。

含めるサービスと固定イメージは以下とする。

|サービス|image|参照 / 備考|
|---|---|---|
|`chroma`|`docker.io/chromadb/chroma:1.5.8`|[Docker Hub](https://hub.docker.com/r/chromadb/chroma/tags "https://hub.docker.com/r/chromadb/chroma/tags")。本番では `1.5.8` の正式タグ確認後に固定する。|
|`open-webui-pipelines`|`ghcr.io/open-webui/pipelines:main`|[GitHub](https://github.com/open-webui/pipelines "https://github.com/open-webui/pipelines")|
|`docling-serve`|`quay.io/docling-project/docling-serve:v1.16.1`|[GitHub](https://github.com/docling-project/docling-serve/pkgs/container/docling-serve)|
|`searxng`|`docker.io/searxng/searxng:2026.4.13-ee66b070a`|[Docker Hub](https://hub.docker.com/r/searxng/searxng/tags "https://hub.docker.com/r/searxng/searxng/tags")|
|`carbone`|`docker.io/carbone/carbone-ee:full-5.4.5`|[Docker Hub](https://hub.docker.com/r/carbone/carbone-ee/tags "https://hub.docker.com/r/carbone/carbone-ee/tags")|
|`carbone-mcp`|`docker.io/carbone/carbone-mcp:1.1.1`|[Docker Hub](https://hub.docker.com/r/carbone/carbone-mcp/tags "https://hub.docker.com/r/carbone/carbone-mcp/tags")|

この compose のうち外部公開対象は Carbone と Carbone MCP のみとする。Chroma、Open WebUI Pipelines、Docling Serve、SearXNG は原則非公開とし、Open WebUI、Dify、内部サービスからのみ利用する。

---

## 4. コーディング

### 4.1 コーディング支援・コーディングエージェント

本基盤では、コーディング支援・コーディングエージェントを **Compose 上の中核サービス**としては持たず、**利用者環境から LiteLLM を参照する形**を基本とする。
バックエンドは `LiteLLM -> vLLM` とし、主力モデルは `Qwen3-Coder` 系を想定する。
コーディング支援ツールからの LLM 呼び出しは LiteLLM の virtual key / tag / user 情報で利用元を識別し、Langfuse に一元的に記録する。

この方針により、Roo Code、Continue、Cline、OpenHands、Tabby などのツールは、基盤側ではなく **クライアント/エージェント側の選択肢**として扱える。
Compose には抱え込まず、LLM API 層だけを共通化する設計にする。

想定するコーディングエージェント・コーディング支援ツールは以下の通りです。

- Roo Code ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=RooVeterinaryInc.roo-cline))
- Cline ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev))
- Continue ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=Continue.continue))
- OpenHands ([GitHub](https://github.com/OpenHands/OpenHands)) ([HP](https://openhands.dev/))
- OpenCode ([GitHub](https://github.com/anomalyco/opencode)) ([HP](https://opencode.ai/ja))
- Tabby ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=TabbyML.vscode-tabby)) ([GitHub](https://github.com/TabbyML/tabby)) ([HP](https://www.tabbyml.com/))
- Codex CLI ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=openai.chatgpt)) ([GitHub](https://github.com/openai/codex)) ([HP](https://developers.openai.com/codex/cli))
- Claude Code ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)) ([HP](https://code.claude.com/docs/ja/overview))

### 4.2 MCPサーバ

MCP サーバは **原則として Compose 管理対象には含めない**。
利用時は **コーディング支援ツールやコーディングエージェントから個別接続**する。これは、`filesystem` や `git` のような MCP がアクセス境界を強く持つため、共通インフラ化するよりもツール側で閉じた方が安全だからである。
例外として、Carbone MCP は文書生成基盤の公式 companion として `docker-compose.knowledge.yml` に含め、`51001/tcp` で外部公開する。

想定する MCP は以下である。

- `filesystem-mcp`
- `git-mcp`
- `memory-mcp`
- `sequential-thinking-mcp`
- `time-mcp`
- `carbone-mcp`

---

## 5. アクセス管理グループ

アクセス管理は、複雑化を避けて **3グループ**に絞る。

- `admins`
    Keycloak、LiteLLM、Langfuse、Dify、deepwiki-open、Paperless-ngx を含む全体管理者

- `builders`
    Dify、deepwiki-open、文書生成テンプレート、文書管理高度利用などの設計・構築担当

- `users`
    Open WebUI、Dify アプリ利用、文書検索・閲覧などの一般利用者

従来の細分化案よりも運用が軽く、SSO グループ運用と各アプリ内権限の役割分担もしやすい。

---

## 6. 各ジャンル生成AIサービス選定（Option Framing）

### 6.1 LLM 推論基盤

- **採用: vLLM**
    ライセンスは **Apache-2.0**。商用利用は可能。公式に Docker Hub の `vllm/vllm-openai` を案内している。 ([GitHub](https://github.com/vllm-project/vllm "https://github.com/vllm-project/vllm"))

- **保留: Ollama**
    ライセンスは **MIT**。商用利用は可能。ローカル軽量運用には有力だが、今回の中核は LiteLLM + vLLM とする。 ([GitHub](https://github.com/ollama/ollama/blob/main/LICENSE "https://github.com/ollama/ollama/blob/main/LICENSE"))

### 6.2 LLM Gateway / API 集約

- **採用: LiteLLM**
    OSS の中核は **MIT**。商用利用は可能。self-host の AI Gateway として適している。なお一部 Enterprise 機能やサポートは商用ライセンス領域がある。 ([GitHub](https://github.com/BerriAI/liteLLM-proxy/blob/main/LICENSE "https://github.com/BerriAI/liteLLM-proxy/blob/main/LICENSE"))

### 6.3 チャット UI

- **採用: Open WebUI**
    v0.6.6+ 以降は **BSD-3 ベースに branding restriction を追加した独自条件**。内部利用や branding 維持前提なら商用利用は実質可能だが、**大規模利用や rebrand 前提では条件確認が必要**。 ([Open WebUI](https://docs.openwebui.com/license "https://docs.openwebui.com/license"))

- **保留: AnythingLLM**
    **MIT**。商用利用は可能。多機能だが、今回は Open WebUI に主ポータルを一本化する。 ([GitHub](https://github.com/mintplex-labs/anything-llm "https://github.com/mintplex-labs/anything-llm"))

- **保留: LibreChat**
    **MIT**。商用利用は可能。MCP や multi-provider は強いが、今回は不採用。 ([GitHub](https://github.com/danny-avila/LibreChat "https://github.com/danny-avila/LibreChat"))

- **保留: LobeChat**
    今回の検索では license 詳細の一次ソース確認を省略したため、**再評価時に要確認**。現時点では Option のみ保持する。
    ※ここは今回、確証ある一次ソースを十分取得できていない。

- **除外: Hugging Face Chat UI / BionicGPT / Chat Nio**
    同系統 UI の重複導入を避けるため。今回は Open WebUI を優先する。

### 6.4 コードベース Wiki 化 (Deepwiki 代替)

- **採用: deepwiki-open**
    **MIT**。商用利用は可能。公式 README は GHCR 配布を案内している。なおメンテナは継続中だが、主開発が AsyncReview 側に寄る旨が告知されているため、将来の置換余地は残す。 ([GitHub](https://github.com/AsyncFuncAI/deepwiki-open "https://github.com/AsyncFuncAI/deepwiki-open"))

- **保留: OpenDeepWiki**
    **MIT**。商用利用は可能。enterprise service 記載はあるが、OSS 本体は MIT。 deepwiki-open の代替候補として保持する。 ([GitHub](https://github.com/AIDotNet/OpenDeepWiki "https://github.com/AIDotNet/OpenDeepWiki"))

- **保留: CodeWiki**
    **MIT**。商用利用は可能。 ([GitHub](https://github.com/FSoft-AI4Code/CodeWiki))

- **保留: deepwiki-rs**
    **MIT**。商用利用は可能。Rust 実装の代替候補として保持する。 ([GitHub](https://github.com/sopaco/deepwiki-rs))

### 6.5 リサーチノート (NotebookLM 代替)

- **除外: Open Notebook**
    **MIT**。商用利用は可能。機能は魅力的だが、今回は Open WebUI + Chroma + Paperless-ngx + Docling で初期要件を吸収する。 ([GitHub](https://github.com/lfnovo/open-notebook "https://github.com/lfnovo/open-notebook"))

- **保留: Insights LM / SurfSense / KnowNote / Quivr / Khoj / Verba / RAGFlow / PrivateGPT**
    今回は中核構成に含めず、NotebookLM 代替を再評価する際の候補として保持する。

### 6.6 Deep Research

- **保留: OpenDeepResearch**
    Deep Research 領域を後続フェーズで扱う際の候補として保持する。 ([GitHub](https://github.com/nickscamara/open-deep-research))

### 6.7 ノーコード / AI アプリ構築

- **採用: Dify**
    **Dify Open Source License**（Apache-2.0 ベースに追加条件あり）。**商用利用は可能**だが、**multi-tenant 運用や frontend branding 改変には商用ライセンス条件が掛かる**。今回の単一組織利用なら適合しやすい。 ([GitHub](https://github.com/langgenius/dify/blob/main/LICENSE "https://github.com/langgenius/dify/blob/main/LICENSE"))

- **除外: n8n**
    Dify と役割が重なるため、今回の初期構成では重複導入を避ける。

- **保留: Flowise**
    コアは **Apache-2.0** だが、`enterprise/` 配下は Commercial License。商用利用自体は可能だが、ライセンスが混在する。さらに 2026 年 4 月時点で重大脆弱性の悪用報告があり、公開運用には慎重さが必要。 ([GitHub](https://github.com/FlowiseAI/Flowise/blob/main/LICENSE.md "https://github.com/FlowiseAI/Flowise/blob/main/LICENSE.md"))

- **保留: Langflow**
    GitHub 上で完全な license 本文取得は今回不足したが、公開リポジトリ運用・OSS 前提のプロジェクトである。再評価時に一次ソース再確認を前提とする。 ([GitHub](https://github.com/langflow-ai/langflow "https://github.com/langflow-ai/langflow"))

### 6.8 文書レビュー・整理

- **採用: Paperless-ngx**
    **GPL-3.0**。商用利用は可能だが、再配布や派生物には copyleft 条件が掛かる。 self-host 利用なら実務上採りやすい。 ([GitHub](https://github.com/paperless-ngx/paperless-ngx "https://github.com/paperless-ngx/paperless-ngx"))

- **保留: OpenContracts / Paperless-AI**
    今回は汎用文書管理を優先し、専門用途は後段で再評価する。

### 6.9 文書生成 (Genspark代替)

- **採用: Carbone**
    Docker Edition は **無料で利用開始可能**だが、advanced/enterprise 機能とサポートは **商用ライセンス**。したがって、**商用利用は可能だが条件付き**と整理する。 ([Docker Hub](https://hub.docker.com/r/carbone/carbone-ee "https://hub.docker.com/r/carbone/carbone-ee"))

- **採用: Carbone MCP**
    公式 MCP コンテナは公開されているが、今回取得した一次ソースでは **OSS ライセンス表記を明確に確認できなかった**。したがって、**Carbone 本体に従属する公式 companion とみなし、最終導入前にベンダ条件確認が必要**とする。商用利用可否も同様に要確認。 ([Docker Hub](https://hub.docker.com/r/carbone/carbone-mcp "https://hub.docker.com/r/carbone/carbone-mcp"))

### 6.10 RAG / 文書解析

- **採用: Chroma**
    **Apache-2.0**。商用利用は可能。ベクタ DB として採用。 ([GitHub](https://github.com/chroma-core/chroma "https://github.com/chroma-core/chroma"))

- **採用: Docling Serve**
    **MIT**。商用利用は可能。API サービスとして利用しやすい。 ([GitHub](https://github.com/docling-project/docling-serve "https://github.com/docling-project/docling-serve"))

- **採用: SearXNG**
    **AGPL-3.0**。商用利用は可能だが、ネットワーク提供時の copyleft 条件に注意が必要。内部用途中心なら採用可能。 ([GitHub](https://github.com/searxng/searxng "https://github.com/searxng/searxng"))

- **採用: Open WebUI Pipelines**
    **MIT**。商用利用は可能。 ただし upstream 自身が「不要なら使わない方がよい」と明記しており、重い前処理/専用ワークフローが必要な範囲で限定採用する。 ([GitHub](https://github.com/open-webui/pipelines "https://github.com/open-webui/pipelines"))

### 6.11 会議文字起こし・要約 (Otter 代替)

結論: **除外**
今回の最終構成では、会議文字起こし・要約基盤は導入しない。

候補:

- **保留: OpenTranscribe**
    ライセンスは **AGPL-3.0**。商用利用自体は可能だが、ネットワーク越しに提供する場合や改変版を運用する場合には、AGPL に基づくソース開示義務の検討が必要である。WhisperX、話者分離、要約、検索まで一体化した self-host 基盤として完成度が高く、**将来この領域を採用する場合の第一候補**である。 ([github.com](https://github.com/davidamacey/OpenTranscribe?utm_source=chatgpt.com), [docs.opentranscribe.app](https://docs.opentranscribe.app/?utm_source=chatgpt.com))

- **保留: Meetily**
    Community Edition は **MIT** で、商用利用可能と明示されている。加えて Business / Pro 向けの商用ライセンス提供も案内されており、**ライセンス面の扱いやすさでは有力**である。一方で、現在の訴求はデスクトップ/ローカル処理寄りであり、今回想定しているサーバ中心の Compose 構成とはやや距離がある。 ([meetily.ai](https://meetily.ai/open-source?utm_source=chatgpt.com), [meetily.ai](https://meetily.ai/license-request/organization/?utm_source=chatgpt.com))

- **保留: MeetMemo**
    ライセンスは **MIT**。商用利用は可能。Docker / Compose 前提のオフライン文字起こし Web アプリとしてまとまっており、ローカル志向の導入には向く。ただし、プロジェクト規模や成熟度では OpenTranscribe より小さく、**組織基盤としての採用は再評価前提**とする。

- **保留: Scriberr**
    ライセンスは **MIT**。商用利用は可能。完全オフラインの self-host transcription という点は魅力だが、現時点では音声文字起こしツールとしての位置づけが強く、会議基盤としての統合性や組織運用の観点では追加評価が必要である。

- **保留: Nojoin / Pensieve**
    今回は一次ソース上でライセンスや運用条件を十分確認できなかったため、**名称のみ保持し、再評価時に精査**とする。

判断理由:
現時点の主目的は、チャット、RAG、文書検索、文書生成、AI アプリ構築、コーディング支援という生成 AI 基盤の中核機能を整備することである。
会議文字起こしまで同時導入すると、GPU 設計、保存容量、機密会議データの運用統制まで範囲が広がるため、今回は除外する。
後日採用する場合は、サーバ中心で組織利用を見据えるなら OpenTranscribe、ライセンスの扱いやすさとローカル志向を重視するなら Meetily / MeetMemo / Scriberr を再評価する。

---

### 6.12 コードレビュー (CodeRabbit 代替)

結論: **除外**
今回の最終構成では、PR レビュー自動化基盤は導入しない。

候補:

- **保留: PR-Agent**
    OSS の PR レビューエージェントとして知名度が高い。リポジトリ上ではオープンソース版として継続公開されており、Qodo の商用サービスとは分かれている。初期の PoC 候補としては有力だが、現在は「community-maintained legacy project」という位置づけも見えるため、**長期運用前提ではメンテナンス体制を見極める必要がある**。

- **保留: OpenReview**
    Vercel Labs が公開する **オープンソースの self-hosted AI code review bot**。現時点では **beta** と明記されており、実験的色が強いが、GitHub App としての導入イメージは明快である。**セルフホスト志向の技術検証候補**として保持する。

- **保留: Kodus**
    Community / Teams / Enterprise の区分があり、Community は free to use and modify とされている一方、商用 SaaS としての強いプロダクト性がある。**単純な OSS 代替というより製品評価対象**として見るべきで、セルフホスト/商用利用条件は導入時に詳細確認が必要である。

- **保留: [ai-review](https://github.com/Nikita-Filonov/ai-review)**
    今回は対象プロジェクトを一意に特定できず、一次ソース上でライセンスと成熟度を十分確認できなかったため、**名称のみ保持し、再評価時に要精査**とする。

判断理由:
まず LiteLLM + vLLM を中核としたコーディング支援・コーディングエージェント基盤を整備し、その後に PR レビュー自動化を足す方が導入順として自然である。
将来的に GitHub / GitLab 上でレビュー効率化が主課題になった時点で、PoC は PR-Agent または OpenReview、本格導入比較は Kodus を含めて再評価する。

---

### 6.13 チャットツール連携アシスタント

結論: **除外**
今回の最終構成では、Slack / Discord / Telegram 等のチャット基盤へ AI アシスタントを常駐させる構成は導入しない。

候補:

- **保留: Hermes Agent**
    ライセンスは **MIT**。商用利用は可能。

- **保留: OpenClaw**
    ライセンスは **MIT**。商用利用は可能。オープンソースの自己ホスト型 AI アシスタント基盤として非常に柔軟で、各種チャットツールやローカル実行を含めた自動化に向く。一方で、強い実行権限や外部連携を扱える分、**権限設計とセキュリティ統制が難しい**。最近は第三者スキルや権限誤設定に関するセキュリティ懸念も報告されており、**導入するなら最小権限・隔離環境・監査ログ前提**とすべきである。

- **保留: AstrBot**
    ライセンスは **AGPL-v3**。商用利用は可能だが、改変してネットワークサービスとして提供する場合には AGPL 上の義務に留意が必要である。Discord / Telegram / Slack などへの接続や、プラグイン/MCP/knowledge base 連携が明示されており、**チャットボット型の基盤候補としては有力**である。

- **保留: CoPaw / HiClaw / Sentient**
    今回は一次ソースでライセンス、配布形態、商用利用条件を十分確認できなかったため、**名称のみ保持し、再評価時に要調査**とする。

判断理由:
まず Open WebUI を主ポータルとして定着させることを優先する。
チャット連携 Bot は、運用面・権限面・監査面の考慮が大きく、誤操作、情報流出、権限逸脱のリスクが他領域より高い。
将来導入する場合でも、まずは OpenClaw または AstrBot を小規模な限定用途で PoC する。

---

## 7. 結論

今回の改訂版における最終構成の核は次の通りである。

- **Open WebUI** を利用者向け主ポータルとする
- **LiteLLM** を外部公開する唯一の LLM API とする
- **Langfuse** を LLM observability、評価、プロンプト管理の集約先とし、LiteLLM は必ず Langfuse に連携する
- **vLLM** を推論基盤の中核とする
- **Dify** を AI アプリ構築基盤として採用し、**n8n は除外**する
- **deepwiki-open** をコードベース理解用途で採用する
- **Paperless-ngx** を文書保管・OCR・検索基盤として採用する
- **Carbone + Carbone MCP** を成果物生成基盤として採用する
- **MCP サーバは原則 Compose 管理対象外** とし、コーディング支援ツール側で利用する。ただし **Carbone MCP** は文書生成基盤の一部として Compose 管理対象に含める
- **アクセス管理グループは `admins` / `builders` / `users` の 3 グループ**に整理する。

実装上は、ライセンスの癖が強いものとして **Open WebUI、Dify、Paperless-ngx、SearXNG、Carbone 系**を意識しておくべきである。
このうち、**Open WebUI は branding 条件**、**Dify は追加条項付き OSS ライセンス**、**Paperless-ngx と SearXNG は copyleft 系**、**Carbone / Carbone MCP は商用条件確認が必要**という整理になる。 ([Open WebUI](https://docs.openwebui.com/license "https://docs.openwebui.com/license"))

この構成であれば、チャット、RAG、文書検索、文書生成、AI アプリ構築、コーディング支援を、サービス重複を抑えつつ一貫した生成AI基盤として構築できる。
次の具体化フェーズでは、各 compose ごとに `depends_on`、`networks`、`volumes`、`profiles`、`healthcheck` を落とし込んだ実装ドラフトを作るのが自然である。
