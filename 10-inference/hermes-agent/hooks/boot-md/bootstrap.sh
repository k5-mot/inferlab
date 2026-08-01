#!/usr/bin/env bash
set -eu

# Hermes の bind mount 配下だけに初期化済みマーカーとスキル導入物を閉じ込める。
HERMES_HOME="${HERMES_HOME:-/opt/data}"
BOOTSTRAP_STAMP="${HERMES_HOME}/.bootstrap-v1"

export HOME="${HERMES_HOME}"
export npm_config_prefix="${HERMES_HOME}/.local"
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

mkdir -p "${HERMES_HOME}/.local/bin"

if [ -f "${BOOTSTRAP_STAMP}" ]; then
  echo "bootstrap already completed: ${BOOTSTRAP_STAMP}"
  exit 0
fi

# 起動後に使うスキル定義をデータ領域へ導入する。
npx skills@latest add mattpocock/skills code-review codebase-design diagnosing-bugs domain-modeling grill-me grill-with-docs grilling handoff implement improve-codebase-architecture prototype research resolving-merge-conflicts setup-matt-pocock-skills tdd teach to-spec to-tickets triage wayfinder writing-great-skills --agent universal -y
npx skills@latest add k5-mot/agent-skills llm-activity-report-skill open-webui-skill tech-news-report-skill translate-ja --agent universal -y
uvx -- graphify install --project --platform agents

# 再起動ごとの重複導入を避けるため、成功後にマーカーを残す。
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${BOOTSTRAP_STAMP}"
echo "bootstrap completed: ${BOOTSTRAP_STAMP}"
