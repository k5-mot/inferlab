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

| Compose                               | 主なサービス                                                                                 |
| ------------------------------------- | -------------------------------------------------------------------------------------------- |
| `docker-compose.common.yml`           | keycloak, postgres-keycloak                                                                  |
| `docker-compose.inference-ollama.yml` | litellm, ollama, ollama-init, inifinity                                                      |
| `docker-compose.inference-vllm.yml`   | litellm, vllm-*                                                                              |
| `docker-compose.openwebui.yml`        | open-webui, kokoro-web, chroma, open-webui-pipelines, docling-serve, searxng, oauth2-proxy-* |
| `docker-compose.comfyui.yml`          | comfyui                                                                                      |
| `docker-compose.carbone.yml`          | carbone, carbone-mcp                                                                         |
| `docker-compose.hermes-agent.yml`     | hermes-agent                                                                                 |
| `docker-compose.openclaw.yml`         | openclaw                                                                                     |
| `docker-compose.dify.yml`             | dify-*                                                                                       |
| `docker-compose.langfuse.yml`         | langfuse, postgres-langfuse, clickhouse, redis-langfuse                                      |
| `docker-compose.paperless.yml`        | paperless-*                                                                                  |
| `docker-compose.deepwiki.yml`         | deepwiki-open                                                                                |

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
| LiteLLM                |    `40000` | 外部向け OpenAI 互換 API |
| Carbone MCP            |    `51001` | oauth2-proxy 経由        |

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
docker compose --profile hermes-agent up -d
docker compose --profile openclaw up -d
docker compose --profile hermes-agent --profile openclaw up -d
```

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
  dist/index.js config set --batch-json '[{"path":"gateway.mode","value":"local"},{"path":"gateway.bind","value":"lan"},{"path":"gateway.controlUi.allowedOrigins","value":["http://localhost:31007","http://127.0.0.1:31007","http://192.168.3.10:31007"]}]'
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
Control UI は `http://127.0.0.1:31007/` または `http://192.168.3.10:31007/` を開き、`./openclaw/openclaw.json` の `gateway.auth.token` か `OPENCLAW_GATEWAY_TOKEN` の値を入力する。
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
  --env-file ./.env \
  --profile common \
  --profile inference-ollama \
  --profile hermes-agent \
  --profile openwebui \
  down --remove-orphans
docker compose \
  --env-file ./.env \
  --profile common \
  --profile inference-ollama \
  --profile hermes-agent \
  --profile openwebui \
  up -d --no-deps --force-recreate --remove-orphans
docker compose \
  --env-file ./.env \
  --profile common \
  --profile inference-ollama \
  --profile hermes-agent \
  --profile openwebui \
  ps
```
