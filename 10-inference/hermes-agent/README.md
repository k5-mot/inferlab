# Hermes Agent

このディレクトリは、`10-inference/docker-compose.yml` の `hermes-agent` サービス向けの設定と初期化手順を置く場所です。

## 永続化される状態

Hermes Agent の実行時状態は、Compose で以下に bind mount されます。

```text
./hermes-agent/hermes-home:/opt/data/.hermes
```

`hermes-home/` には `SOUL.md`、`config.yaml`、`auth.json`、`skills/`、`memories/`、`sessions/`、`state.db`、`cron/`、`plugins/`、`logs/` などのローカル状態や秘密情報が入るため、Git管理しません。

## 初期セットアップ

以前は `hermes-config.yaml` の `agent.system_prompt` に初期セットアップ手順を書いていましたが、これは毎回の会話で実行対象になりやすく、依存関係のインストールを通常会話の責務にしてしまうため避けます。

代わりに、初回構築時または依存関係を更新したいタイミングで以下を実行します。

```bash
cd 10-inference/hermes-agent
./setup-hermes-agent.sh
```

このスクリプトは `hermes-agent` コンテナ内で以下を実行します。

```bash
npx skills@latest add mattpocock/skills -y
npx skills@latest add k5-mot/agent-skills -y
uv add langfuse
uv add --dev "docling-mcp[local]"
npm -g install mcp-searxng
```

## 設定ファイル

`hermes-config.yaml` は Compose で以下に read-only mount されます。

```text
./hermes-agent/hermes-config.yaml:/opt/data/.hermes/config.yaml:ro
```

Dashboardや `hermes config set` から設定を変更したい場合は、read-only mountを外して `hermes-home/config.yaml` を運用ファイルにしてください。
