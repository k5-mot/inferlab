#!/bin/sh
set -eu

# 起動時に必要な値だけをテンプレートへ流し込み、設定の本体はJSON側に置く。
CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-${OPENCLAW_HOME:-/home/node}/.openclaw}"
CONFIG_TEMPLATE_SOURCE_PATH="${OPENCLAW_CONFIG_TEMPLATE_SOURCE_PATH:-/usr/local/share/openclaw/openclaw.template.json}"
CONFIG_SCHEMA_SOURCE_PATH="${OPENCLAW_CONFIG_SCHEMA_SOURCE_PATH:-/usr/local/share/openclaw/openclaw.schema.json}"
CONFIG_TEMPLATE_PATH="${OPENCLAW_CONFIG_TEMPLATE_PATH:-${CONFIG_DIR}/openclaw.template.json}"
CONFIG_SCHEMA_PATH="${OPENCLAW_CONFIG_SCHEMA_PATH:-${CONFIG_DIR}/openclaw.schema.json}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${CONFIG_DIR}/openclaw.json}"

: "${DISCORD_BOT_TOKEN:?DISCORD_BOT_TOKEN is required}"
: "${DISCORD_GUILD_ID:?DISCORD_GUILD_ID is required}"
: "${DISCORD_CHANNEL_ID:?DISCORD_CHANNEL_ID is required}"

mkdir -p "${CONFIG_DIR}" "$(dirname "${CONFIG_PATH}")" "$(dirname "${CONFIG_TEMPLATE_PATH}")" "$(dirname "${CONFIG_SCHEMA_PATH}")"

# 旧imageで導入したLangfuse bridgeは、観測経路をLiteLLMへ集約する方針では読み込ませない。
rm -rf "${CONFIG_DIR}/extensions/langfuse-bridge"

# named volumeの初回コピーは既存volumeには効かないため、テンプレート類だけは毎回image側から反映する。
cp "${CONFIG_TEMPLATE_SOURCE_PATH}" "${CONFIG_TEMPLATE_PATH}"
cp "${CONFIG_SCHEMA_SOURCE_PATH}" "${CONFIG_SCHEMA_PATH}"

# Discordのroutingに必要なIDだけをテンプレートへ展開する。
envsubst '${DISCORD_GUILD_ID} ${DISCORD_CHANNEL_ID}' < "${CONFIG_TEMPLATE_PATH}" > "${CONFIG_PATH}"

# DockerfileのCMDは最小引数に保ち、環境変数でbind modeだけ差し替えられるようここで補完する。
if [ "$#" -eq 3 ] && [ "$1" = "node" ] && [ "$2" = "dist/index.js" ] && [ "$3" = "gateway" ]; then
  set -- "$@" --bind "${OPENCLAW_GATEWAY_BIND:-lan}" --port "18789"
fi

exec "$@"
