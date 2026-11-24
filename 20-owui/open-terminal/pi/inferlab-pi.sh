#!/usr/bin/env bash
# Open TerminalからPiを起動する前に、InferLab管理のPi設定をuserのagent directoryへ配布する。
# Open TerminalはPI_*環境変数を他userへ渡さないため、PI_CODING_AGENT_DIRではなく
# 各userの~/.pi/agentへ配置する。
set -euo pipefail

readonly MANAGED_DIR=/etc/inferlab/pi/agent
readonly AGENT_DIR="${HOME}/.pi/agent"

# 管理対象fileをuserのagent directoryへ同期する。
# 引数: なし。
# 戻り値: 0。user独自のsession、auth.json、追加skillは変更しない。
sync_managed_config() {
  mkdir -p "${AGENT_DIR}/skills"
  # model定義とsettingsはrepository側をauthoritative sourceとして毎回上書きする。
  cp "${MANAGED_DIR}/models.json" "${AGENT_DIR}/models.json"
  cp "${MANAGED_DIR}/settings.json" "${AGENT_DIR}/settings.json"
  # 管理skillだけを置き換え、userが追加したskillは残す。
  local skill
  for skill in "${MANAGED_DIR}"/skills/*; do
    rm -rf "${AGENT_DIR}/skills/$(basename "${skill}")"
    cp -r "${skill}" "${AGENT_DIR}/skills/"
  done
}

sync_managed_config
exec /usr/local/bin/pi "$@"
