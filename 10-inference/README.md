# 10-inference

LiteLLM、Ollama、TEI、Hermes-Agent、OpenClaw、Kokoroをまとめた推論stack。

## 起動時初期化

このstackには、通常のdaemon起動以外に次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `ollama-init` | Compose内のinit commandで`OLLAMA_INIT_MODELS`に列挙したmodelを`ollama-cache` volumeへ順次pullする。Cloud modelのpullはsign in前でも成功するが、実行にはOllama serviceでのsign inが必要。 |
| `litellm` | `litellm/config-litellm.yaml`を読み込み、Ollama、TEI、外部provider、Langfuse連携をまとめる。Ollama chat modelはtool callの本文JSON漏れを避けるため、`ollama_chat/...` routeを使う。 |
| `hermes-agent` | LiteLLM向けの相関ID header bridgeを有効にしてgatewayを起動する。Langfuseへの送信はLiteLLMに集約する。 |
| `openclaw` | custom imageでtemplate/schema/entrypointを同梱し、`.env`と環境変数から実行時設定を生成する。Langfuseへの送信はLiteLLMに集約する。 |

`ollama`は`ollama-init`の完了後に本体serviceを起動する。初回はmodel取得に時間がかかる。Ollama Cloud modelの実行前は、起動後の`ollama` serviceでOllama Cloudへsign inする。

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
- `kokoro`がhealthcheckに成功する。

失敗条件:

- Ollama Cloud modelの取得先へ接続できない。
- Ollama Cloud model実行時にOllama Cloudのsign inが要求される。
- TEIがmemory不足で再起動を繰り返す。
- LiteLLMの設定解決に失敗する。
- Hermes-AgentがOpen WebUIまたはLiteLLMへ接続できない。

## Langfuse連携

Langfuseへの送信はLiteLLMの`langfuse_otel` callbackに集約する。Hermes-AgentとOpenClawはLangfuse SDKやLangfuse pluginから直接送信せず、LiteLLMへのprovider requestに`langfuse_*` headerまたはmetadataを付与する。

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
