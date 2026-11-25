#!/usr/bin/env bash
# Open Terminal本来のentrypointの前に、InferLabの初期化を行う。
# 1. llm-brokerを専用OS userで起動する。brokerはLiteLLM master keyを持つため、Open Terminal serverと
#    user processの環境変数へkeyを残さない。どちらかが終了したらcontainerごと終了させ、restart policyで
#    再起動する。broker停止中にuser processがbrokerのportを奪うことを防ぐため。
# 2. 既存userのhomeへ、共通のAGENTS.mdとskillのlinkを張る。新規userには/etc/skelから配られる。
set -euo pipefail

readonly BROKER_URL=http://127.0.0.1:8765
readonly BROKER_ENV=LLM_BROKER_LITELLM_API_KEY,LLM_BROKER_LITELLM_URL
readonly AGENT_DIR=/etc/inferlab/agent

# brokerが応答するまで待つ。
# 引数: なし。
# 戻り値: 応答した場合0、10秒以内に応答しない場合1。
wait_for_broker() {
  local _
  for _ in $(seq 1 50); do
    if curl -fsS -o /dev/null "${BROKER_URL}/health" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# 子processへSIGTERMを送り、終了を待つ。
# 引数: なし。
# 戻り値: 0。
stop_children() {
  kill -TERM "${server_pid:-}" "${broker_pid:-}" 2>/dev/null || true
  wait || true
}

# 既存userのhomeへ、AGENTS.mdとskill directoryのlinkを作る。
# Open WebUIとPiはhomeの~/AGENTS.mdと~/.agents/skillsを読む。userが自分で置いたfileは上書きしない。
# container再作成直後はOS userがまだ無く (Open Terminalが初回requestで作る)、そのuserとしては作れない。
# rootで作り、所有者はOpen Terminalがuser作成時に行うhomeの`chown -R`で揃える。
# 引数: なし。
# 戻り値: 0。
link_agent_files() {
  local home
  for home in /home/*; do
    # Open Terminal server自身 (/home/user) は対象外。
    [[ -d "${home}" && "${home}" != /home/user ]] || continue
    sudo -n sh -c '
      [ -e "$1/AGENTS.md" ] || [ -L "$1/AGENTS.md" ] || ln -s "$2/AGENTS.md" "$1/AGENTS.md"
      mkdir -p "$1/.agents"
      [ -e "$1/.agents/skills" ] || [ -L "$1/.agents/skills" ] || ln -s "$2/skills" "$1/.agents/skills"
    ' _ "${home}" "${AGENT_DIR}" || echo "inferlab-entrypoint: ${home}へlinkを作れませんでした。" >&2
  done
}

# -Iでcwdやuser site-packagesを読まない。sudoはenv_resetのため必要な変数だけを渡す。
sudo -n --preserve-env="${BROKER_ENV}" -u llm-broker \
  /usr/bin/python3 -I /usr/local/lib/inferlab/llm_broker.py &
broker_pid=$!
unset LLM_BROKER_LITELLM_API_KEY

if ! wait_for_broker; then
  echo "inferlab-entrypoint: llm-brokerが起動しませんでした。" >&2
  stop_children
  exit 1
fi

link_agent_files

/app/entrypoint.sh "$@" &
server_pid=$!
trap 'stop_children; exit 143' TERM INT

status=0
wait -n "${broker_pid}" "${server_pid}" || status=$?
echo "inferlab-entrypoint: 子processが終了しました (status=${status})。containerを終了します。" >&2
stop_children
exit "$((status == 0 ? 1 : status))"
