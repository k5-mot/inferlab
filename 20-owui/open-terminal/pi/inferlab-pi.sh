#!/usr/bin/env bash
# Open TerminalからPiを起動する前に、InferLab管理のmodel定義とsettingsをuserのagent directoryへ配布する。
# Open TerminalはPI_*環境変数を他userへ渡さないため、PI_CODING_AGENT_DIRではなく各userの~/.pi/agentへ置く。
# AGENTS.mdとskillは、Open WebUIの通常modelと共通の~/AGENTS.mdと~/.agents/skillsから読む。
set -euo pipefail

readonly MANAGED_DIR=/etc/inferlab/pi/agent
readonly AGENT_DIR="${HOME}/.pi/agent"
# 旧構成で~/.pi/agentへcopyしていた管理対象。共通の場所と二重に読み込まれないよう削除する。
readonly LEGACY_SKILLS=(officecli officecli-docx officecli-pptx officecli-xlsx open-webui)

# 管理対象fileをuserのagent directoryへ同期する。
# 引数: なし。
# 戻り値: 0。user独自のsession、auth.json、追加skillは変更しない。
sync_managed_config() {
  mkdir -p "${AGENT_DIR}"
  # model定義とsettingsはrepository側をauthoritative sourceとして毎回上書きする。
  cp "${MANAGED_DIR}/models.json" "${AGENT_DIR}/models.json"
  cp "${MANAGED_DIR}/settings.json" "${AGENT_DIR}/settings.json"
  local skill
  rm -f "${AGENT_DIR}/AGENTS.md"
  for skill in "${LEGACY_SKILLS[@]}"; do
    rm -rf "${AGENT_DIR:?}/skills/${skill}"
  done
  rm -rf "${AGENT_DIR}"/skills/owui-*
}

sync_managed_config
exec /usr/local/bin/pi "$@"
