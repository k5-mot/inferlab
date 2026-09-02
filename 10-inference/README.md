# 10-inference

LiteLLM、Ollama、TEI、Hermes-Agent、OpenClaw、QwenPaw、Kokoroをまとめた推論stack。

## 起動時初期化

このstackには、通常のdaemon起動以外に次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `ollama-init` | Compose内のinit commandで`OLLAMA_INIT_MODELS`に列挙したmodelを`ollama-cache` volumeへ順次pullする。Cloud modelのpullはsign in前でも成功するが、実行にはOllama serviceでのsign inが必要。 |
| `litellm` | `litellm/config-litellm.yaml`を読み込み、Ollama、TEI、外部provider、Langfuse連携をまとめる。Ollama chat modelはtool callの本文JSON漏れを避けるため、`ollama_chat/...` routeを使う。 |
| `hermes-agent` | LiteLLM向けの相関ID header bridgeを有効にしてgatewayを起動する。Langfuseへの送信はLiteLLMに集約する。 |
| `openclaw-init` | OpenClaw公式imageに含まれないDiscord pluginを、初回だけ`openclaw-data` volumeへ導入する。 |
| `openclaw` | 公式imageでread-onlyの`openclaw/openclaw.json`を読み込む。Langfuseへの送信はLiteLLMに集約する。 |
| `qwenpaw` | 公式imageでConsoleとDiscord channelを起動する。model providerはLiteLLMへ向け、Langfuseへの送信はLiteLLMに集約する。 |

`ollama`は`ollama-init`の完了後に本体serviceを起動する。初回はmodel取得に時間がかかる。Ollama Cloud modelの実行前は、起動後の`ollama` serviceでOllama Cloudへsign inする。

## OpenClaw構成

OpenClawは`ghcr.io/openclaw/openclaw`の公式imageを直接使用する。設定は`openclaw/openclaw.json`を`/home/node/.openclaw/openclaw.managed.json`へread-onlyでmountし、`OPENCLAW_CONFIG_PATH`で参照する。設定のauthoritative sourceはrepositoryとし、Control UIやDiscord channelからの設定書き込みは無効にする。OpenClawが生成する`openclaw.managed.json.last-good`は、同じstate volumeへ保存する。

LiteLLM API keyとDiscord bot tokenはOpenClawのSecretRefでprocess environmentから解決する。Discord guild IDとchannel IDはsecretではなくrouting識別子であり、`openclaw/openclaw.json`へ記録する。接続先を変更する場合は、同fileの`channels.discord.guilds`を更新する。

`openclaw-init`は`openclaw-data` volumeのDiscord plugin versionを確認し、OpenClaw coreと同じrelease cohortへinstallまたはupdateする。Docling MCPは専用コンテナを増やさない方針とし、OpenClawとの連携対象に含めない。

```bash
# read-only設定をOpenClawのschemaで検証する。
sudo docker compose --env-file .env --profile openclaw run --rm --no-deps openclaw node dist/index.js config validate

# OpenClaw profileを起動し、初期化serviceを含めて反映する。
sudo docker compose --env-file .env --profile openclaw up -d

# Discord pluginの読み込み元と状態を確認する。
sudo docker compose --env-file .env --profile openclaw exec openclaw node dist/index.js plugins list

# Discord channelの接続状態を確認する。
sudo docker compose --env-file .env --profile openclaw exec openclaw node dist/index.js channels status --channel discord --probe
```

期待結果:

- `config validate`が成功する。
- `openclaw-init`がexit code `0`で終了する。
- `openclaw`がhealthyになる。
- `plugins list`でDiscord pluginがloadedになる。
- Discord channelのprobeが成功する。

失敗条件:

- read-only設定がschema validationに失敗する。
- Discord pluginの導入または読み込みに失敗する。
- Discord channelのprobeが接続に失敗する。
- OpenClawが`http://127.0.0.1:18789/healthz`で応答しない。

## Ollama Cloudのsign in

Ollama Cloud modelを`Hermes-Agent`、`OpenClaw`、`Open WebUI`から使う場合、Ollama deploymentの通信経路は`LiteLLM -> Ollama -> Ollama Cloud`に限定する。LiteLLMはOllama containerのlocal APIだけを呼び出すため、LiteLLMからOllama containerへ`OLLAMA_API_KEY`を渡さない。

`OLLAMA_API_KEY`は`https://ollama.com/api`へ直接アクセスする場合の認証であり、このstackのOllama Cloud実行経路では使わない。Ollama containerからOllama Cloudへ接続する認証は、`ollama-cache` volumeに保存されたOllamaのsign in状態を使う。

この制約はLiteLLM全体をOllama providerへ限定するものではない。LiteLLMは同じ`model_name`に対してOllama、OpenRouter、Google AI Studio、Groq Cloud、Cloudflare Workers AIなどの複数deploymentを持ち、`router_settings.routing_strategy: simple-shuffle`で候補を分散する。

初回起動時、または`ollama-cache` volumeを削除した後は、inference stackを起動してからsign inする。詳細な初期セットアップ手順は[Initial Setup](../docs/manual/INITIAL_SETUP.md)を参照する。

```bash
# inference stackを起動し、ollama-initでCloud modelを取得する。
sudo docker compose --env-file .env --profile inference up -d

# Ollama Cloudのsign in状態をollama-cache volumeへ保存する。
sudo docker compose --env-file .env --profile inference exec -it ollama ollama signin
```

期待結果:

- ブラウザでOllama Cloudへのsign inを完了できる。
- `ollama-cache` volumeにsign in状態が保存される。
- LiteLLM経由のOllama Cloud model実行が`ollama` serviceのsign in状態を使える。

失敗条件:

- `ollama signin`が完了しない。
- sign in後もOllama Cloud model実行時に`You need to be signed in to Ollama to run Cloud models.`が表示される。
- LiteLLMのOllama deploymentが`https://ollama.com/api`を参照している。

## 起動

```bash
# inference stackを起動する。
sudo docker compose --env-file .env --profile inference up -d
```

期待結果:

- `ollama-init`がmodel取得後に正常終了する。
- `ollama`、`tei-embedding`、`tei-reranking`がhealthyになる。
- `litellm`が`http://${PUBLIC_HOST}:31000/ui`で応答する。
- `qwenpaw`が`http://${PUBLIC_HOST}:31003`で応答する。
- `kokoro`がhealthcheckに成功する。

失敗条件:

- Ollama Cloud modelの取得先へ接続できない。
- Ollama Cloud model実行時にOllama Cloudのsign inが要求される。
- TEIがmemory不足で再起動を繰り返す。
- LiteLLMの設定解決に失敗する。
- Hermes-AgentがOpen WebUIまたはLiteLLMへ接続できない。
- QwenPawのConsole認証情報が未設定、またはDiscord bot tokenが不正である。

## QwenPawの初期設定

QwenPaw Consoleは`http://${PUBLIC_HOST}:31003`で公開する。`QWENPAW_AUTH_ENABLED=true`を固定し、`.env`の`QWENPAW_AUTH_USERNAME`と`QWENPAW_AUTH_PASSWORD`で初期adminを自動登録する。

モデルはQwenPawからLiteLLMへ集約する。QwenPawにはOpenAI互換providerとして次の値を設定する。

| 項目 | 値 |
| --- | --- |
| Base URL | `http://litellm:4000/v1` |
| API Key | `.env`の`LITELLM_MASTER_KEY` |
| Model | `openai/gpt-oss:20b` |

Discord channelは`.env`の`QWENPAW_DISCORD_BOT_TOKEN`をQwenPaw container内の`DISCORD_BOT_TOKEN`へ渡して有効化する。Discordの詳細なアクセス制御はQwenPaw Consoleで管理する。

```bash
# QwenPawだけを再作成して、認証情報とDiscord設定を反映する。
sudo docker compose --env-file .env --profile qwenpaw up -d --force-recreate qwenpaw
```

期待結果:

- `http://${PUBLIC_HOST}:31003`でQwenPaw Consoleにloginできる。
- QwenPawのmodel requestがLiteLLMを経由する。
- LiteLLM経由のrequestがLangfuseに記録される。

失敗条件:

- QwenPaw Consoleにloginできない。
- QwenPawから`http://litellm:4000/v1`へ接続できない。
- Discord bot tokenを設定してもDiscord gatewayへ接続できない。

## Langfuse連携

Langfuseへの送信はLiteLLMの`langfuse_otel` callbackに集約する。Hermes-Agent、OpenClaw、QwenPawはLangfuse SDKやLangfuse pluginから直接送信せず、LiteLLMへのprovider requestへ集約する。

Hermes-Agentは`litellm-langfuse-headers` pluginで、`session_id`、`turn_id`、`sender_id`、`api_request_id`をLiteLLMのLangfuse連携用headerへ変換する。OpenClawはLiteLLM providerの静的headerで、OpenClaw由来のtrace/generation名とtagを渡す。

## 確認手順

```bash
# inference profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile inference ps

# LiteLLMのreadiness endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:31000/health/readiness" >/dev/null

# Ollamaに登録済みmodel一覧を確認する。
sudo docker compose --env-file .env --profile inference exec ollama ollama list
```

期待結果:

- LiteLLM readinessが成功する。
- `ollama list`に`OLLAMA_INIT_MODELS`で指定したmodelが表示される。
- TEIのhealthcheckがhealthyになる。
- QwenPaw Consoleが`http://${PUBLIC_HOST}:31003`で応答する。

失敗条件:

- `ollama-init`が`exited`以外の異常終了になる。
- LiteLLM readinessが5xxまたは接続失敗になる。

## 再初期化

Ollama model cacheを作り直す場合は`ollama-cache` volumeを削除する。

```bash
# inference stackを停止する。
sudo docker compose --env-file .env --profile inference down

# Ollama model cacheを削除する。
sudo docker volume rm "${STACK_NAME}_ollama-cache"

# inference stackを再作成し、model取得を再実行する。
sudo docker compose --env-file .env --profile inference up -d

# Ollama Cloudのsign in状態をollama-cache volumeへ保存する。
sudo docker compose --env-file .env --profile inference exec -it ollama ollama signin
```

期待結果:

- `ollama-init`が再度modelを取得する。
- `ollama-cache` volumeが新規作成される。

失敗条件:

- volumeが使用中で削除できない。
- model取得先へ接続できない。

`ollama-cache` volumeを削除した場合、Cloud modelを再取得する前にOllama Cloudのsign inをやり直す。

## References

- [LiteLLM Ollama Provider](https://docs.litellm.ai/docs/providers/ollama)
- [Ollama API Authentication](https://docs.ollama.com/api/authentication)
- [Ollama Cloud](https://docs.ollama.com/cloud)
- [QwenPaw](https://github.com/agentscope-ai/QwenPaw)
- [QwenPaw Docker Compose](https://raw.githubusercontent.com/agentscope-ai/QwenPaw/main/docker-compose.yml)
- [OpenClaw Docker](https://docs.openclaw.ai/install/docker)
- [OpenClaw Configuration](https://docs.openclaw.ai/gateway/configuration)
- [OpenClaw Discord](https://docs.openclaw.ai/channels/discord)
