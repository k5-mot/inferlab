# 10-inference

LiteLLM、Ollama、TEI、Hermes-Agent、OpenClaw、Kokoroをまとめた推論stack。

## 起動時初期化

このstackには、通常のdaemon起動以外に次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `ollama-init` | `OLLAMA_INIT_MODELS`に列挙したmodelを`ollama-cache` volumeへ順次pullする。 |
| `litellm` | `litellm/config-litellm.yaml`を読み込み、Ollama、TEI、外部provider、Langfuse連携をまとめる。 |
| `hermes-agent` | 起動時に`uv add "langfuse==4.14.1"`を実行してからgatewayを起動する。 |
| `openclaw` | custom imageでtemplate/schema/entrypointを同梱し、`.env`と環境変数から実行時設定を生成する。 |

`ollama`は`ollama-init`の完了後に本体serviceを起動する。初回はmodel取得に時間がかかる。

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

- `OLLAMA_API_KEY`が必要なcloud model取得に失敗する。
- TEIがmemory不足で再起動を繰り返す。
- LiteLLMの設定解決に失敗する。
- Hermes-AgentがOpen WebUIまたはLangfuseへ接続できない。

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
sudo docker volume rm "${STACK_NAME:-inferlab}_ollama-cache"

# inference stackを再作成し、model取得を再実行する。
sudo docker compose --env-file .env --profile inference up -d
```

期待結果:

- `ollama-init`が再度modelを取得する。
- `ollama-cache` volumeが新規作成される。

失敗条件:

- volumeが使用中で削除できない。
- model取得先へ接続できない。
