#!/usr/bin/env bash
set -euo pipefail

# このスクリプトは、Hermes Agentコンテナ内で必要な初期セットアップを明示的に実行する。
# hermes-config.yamlのsystem_promptに毎回セットアップ手順を書く代わりに、
# 初回構築時または依存関係を更新したいタイミングで手動実行する。

cd "$(dirname "$0")/.."

COMPOSE_COMMAND=(docker compose)
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_COMMAND=(docker-compose)
  else
    echo "docker compose または docker-compose が見つかりません。" >&2
    exit 1
  fi
fi

"${COMPOSE_COMMAND[@]}" --profile hermes-agent exec hermes-agent sh -lc '
set -eu

# skills のセットアップ
npx skills@latest add mattpocock/skills -y
npx skills@latest add k5-mot/agent-skills -y

# pip/npm パッケージのセットアップ
uv add langfuse
uv add --dev "docling-mcp[local]"
npm -g install mcp-searxng
'
