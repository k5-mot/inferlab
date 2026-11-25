#!/usr/bin/env bash
# owui-brokerを専用OS userで起動してから、Open Terminal本来のentrypointを起動する。
# brokerはuserのAPI keyとLiteLLM master keyを持つため、Open Terminal serverとuser processの
# 環境変数へkeyを残さない。どちらかが終了したらcontainerごと終了させ、restart policyで
# 再起動する。broker停止中にuser processがbrokerのportを奪うことを防ぐため。
set -euo pipefail

readonly BROKER_URL=http://127.0.0.1:8765
readonly BROKER_ENV=OWUI_BROKER_LITELLM_API_KEY,OWUI_BROKER_TOOL_SERVERS,OWUI_BROKER_OWUI_URL,OWUI_BROKER_LITELLM_URL

# brokerが応答するまで待つ。
# 引数: なし。
# 戻り値: 応答した場合0、10秒以内に応答しない場合1。
wait_for_broker() {
  local _
  for _ in $(seq 1 50); do
    if curl -fsS -o /dev/null "${BROKER_URL}/broker/health" 2>/dev/null; then
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

# -Iでcwdやuser site-packagesを読まない。sudoはenv_resetのため必要な変数だけを渡す。
sudo -n --preserve-env="${BROKER_ENV}" -u owui-broker \
  /usr/bin/python3 -I /usr/local/lib/inferlab/owui_broker.py &
broker_pid=$!
unset OWUI_BROKER_LITELLM_API_KEY OWUI_BROKER_TOOL_SERVERS

if ! wait_for_broker; then
  echo "inferlab-entrypoint: owui-brokerが起動しませんでした。" >&2
  stop_children
  exit 1
fi

/app/entrypoint.sh "$@" &
server_pid=$!
trap 'stop_children; exit 143' TERM INT

status=0
wait -n "${broker_pid}" "${server_pid}" || status=$?
echo "inferlab-entrypoint: 子processが終了しました (status=${status})。containerを終了します。" >&2
stop_children
exit "$((status == 0 ? 1 : status))"
