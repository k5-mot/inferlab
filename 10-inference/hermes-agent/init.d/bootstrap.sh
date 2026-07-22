#!/bin/sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
STAMP_FILE="${HERMES_HOME}/.inferlab-bootstrap-v1"
BOOTSTRAP_STRICT="${HERMES_BOOTSTRAP_STRICT:-false}"

export HOME="${HERMES_HOME}"
export PATH="${HERMES_HOME}/.local/bin:${HERMES_HOME}/bin:${PATH}"
export npm_config_prefix="${HERMES_HOME}/.local"
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

if [ -f "${STAMP_FILE}" ]; then
  exit 0
fi

mkdir -p \
  "${HERMES_HOME}/.local/bin" \
  "${HERMES_HOME}/lazy-packages"

failed=0

# 初期化はコンテナ起動を塞ぎすぎないよう、失敗時は最後にまとめて扱う。
if ! npx --yes skills@latest add mattpocock/skills -y; then
  echo "[inferlab-bootstrap] skills add mattpocock/skills failed" >&2
  failed=1
fi

if ! npx --yes skills@latest add k5-mot/agent-skills -y; then
  echo "[inferlab-bootstrap] skills add k5-mot/agent-skills failed" >&2
  failed=1
fi

# Hermes の永続 Python パッケージ領域に追加し、プロジェクト直下へ pyproject.toml を作らない。
if ! uv pip install --target "${HERMES_HOME}/lazy-packages" langfuse "docling-mcp[local]"; then
  echo "[inferlab-bootstrap] Python package install failed" >&2
  failed=1
fi

# npm のグローバル prefix を /opt/data 配下に固定し、非 root の Hermes ユーザでも更新できるようにする。
if ! npm install --global --prefix "${HERMES_HOME}/.local" mcp-searxng; then
  echo "[inferlab-bootstrap] npm package install failed" >&2
  failed=1
fi

if [ "${failed}" -ne 0 ]; then
  if [ "${BOOTSTRAP_STRICT}" = "true" ]; then
    exit 1
  fi
  echo "[inferlab-bootstrap] bootstrap finished with warnings" >&2
  exit 0
fi

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STAMP_FILE}"
