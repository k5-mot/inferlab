#!/usr/bin/env bash
# Open TerminalからPiを起動する前に、InferLab管理のmodel定義とsettingsをuserのagent directoryへ配布する。
# Open TerminalはPI_*環境変数を他userへ渡さないため、PI_CODING_AGENT_DIRではなく各userの~/.pi/agentへ置く。
# AGENTS.mdとskillは、Open WebUIの通常modelと共通の~/AGENTS.mdと~/.agents/skillsから読む。
set -euo pipefail

readonly MANAGED_DIR=/etc/inferlab/pi/agent
readonly AGENT_DIR="${HOME}/.pi/agent"

mkdir -p "${AGENT_DIR}"
# model定義とsettingsはrepository側をauthoritative sourceとして毎回上書きする。
# user独自のsession、auth.json、追加skillは変更しない。
cp "${MANAGED_DIR}/models.json" "${AGENT_DIR}/models.json"
cp "${MANAGED_DIR}/settings.json" "${AGENT_DIR}/settings.json"
exec /usr/local/bin/pi "$@"
