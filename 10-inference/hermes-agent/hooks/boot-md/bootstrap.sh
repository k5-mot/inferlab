#!/usr/bin/env bash
set -eu

# Hermes の bind mount 配下だけに初期化済みマーカーと導入物を閉じ込める。
HERMES_HOME="${HERMES_HOME:-/opt/data}"
BOOTSTRAP_STAMP="${HERMES_HOME}/.inferlab-bootstrap-v1"

if [ -f "${BOOTSTRAP_STAMP}" ]; then
  echo "bootstrap already completed: ${BOOTSTRAP_STAMP}"
  exit 0
fi

export HOME="${HERMES_HOME}"
export PATH="${HERMES_HOME}/.local/bin:${HERMES_HOME}/bin:${PATH:-}"
export npm_config_prefix="${HERMES_HOME}/.local"
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

mkdir -p \
  "${HERMES_HOME}/.local/bin" \
  "${HERMES_HOME}/lazy-packages"

npx --yes skills@latest add mattpocock/skills -y
npx --yes skills@latest add k5-mot/agent-skills -y
uv pip install --target "${HERMES_HOME}/lazy-packages" langfuse "docling-mcp[local]"
npm install --global --prefix "${HERMES_HOME}/.local" mcp-searxng

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${BOOTSTRAP_STAMP}"
echo "bootstrap completed: ${BOOTSTRAP_STAMP}"
