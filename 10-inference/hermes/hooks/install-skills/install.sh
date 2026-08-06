#!/bin/sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
AGENTS_SKILLS_DIR="${HERMES_HOME}/.agents/skills"

echo "[install-skills] Installing external Agent Skills"

mkdir -p "${AGENTS_SKILLS_DIR}"

cd "${HERMES_HOME}"

echo "[install-skills] mattpocock/skills"

npx skills@latest add mattpocock/skills \
  --skill code-review \
  --skill codebase-design \
  --skill diagnosing-bugs \
  --skill domain-modeling \
  --skill grill-me \
  --skill grill-with-docs \
  --skill grilling \
  --skill handoff \
  --skill implement \
  --skill improve-codebase-architecture \
  --skill prototype \
  --skill research \
  --skill resolving-merge-conflicts \
  --skill setup-matt-pocock-skills \
  --skill tdd \
  --skill teach \
  --skill to-spec \
  --skill to-tickets \
  --skill triage \
  --skill wayfinder \
  --skill writing-great-skills \
  --agent universal \
  --copy \
  -y

echo "[install-skills] k5-mot/agent-skills"

npx skills@latest add k5-mot/agent-skills \
  --skill llm-activity-report-skill \
  --skill open-webui-skill \
  --skill tech-news-report-skill \
  --skill translate-ja \
  --agent universal \
  --copy \
  -y

echo "[install-skills] graphify"

uvx --from graphifyy graphify install \
  --project \
  --platform agents

echo "[install-skills] External Agent Skills installation complete"
