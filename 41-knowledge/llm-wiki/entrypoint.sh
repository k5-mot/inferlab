#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${LLM_WIKI_CONFIG:-/state/config.toml}"
SPACE_NAME="${LLM_WIKI_SPACE_NAME:-inferlab}"
SPACE_PATH="${LLM_WIKI_SPACE_PATH:-/wikis/${SPACE_NAME}}"
HTTP_PORT="${LLM_WIKI_HTTP_PORT:-8080}"

mkdir -p "$(dirname "${CONFIG_PATH}")" "$(dirname "${SPACE_PATH}")"

# llm-wikiの自動commitがcontainer内で失敗しないよう、Git identityを固定する。
git config --global user.name "${GIT_COMMITTER_NAME:-InferLab LLM Wiki}"
git config --global user.email "${GIT_COMMITTER_EMAIL:-llm-wiki@inferlab.local}"

if [ ! -f "${SPACE_PATH}/wiki.toml" ]; then
  llm-wiki --config "${CONFIG_PATH}" spaces create "${SPACE_PATH}" \
    --name "${SPACE_NAME}" \
    --description "InferLab knowledge wiki" \
    --set-default
elif ! grep -q "name = \"${SPACE_NAME}\"" "${CONFIG_PATH}" 2>/dev/null; then
  llm-wiki --config "${CONFIG_PATH}" spaces register "${SPACE_PATH}" \
    --name "${SPACE_NAME}" \
    --description "InferLab knowledge wiki"
fi

llm-wiki --config "${CONFIG_PATH}" config set serve.http_allowed_hosts "localhost,127.0.0.1,::1,llm-wiki" --global

exec llm-wiki --config "${CONFIG_PATH}" serve --http ":${HTTP_PORT}" --watch
