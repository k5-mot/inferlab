#!/usr/bin/env bash
# =============================================================================
# hermes-profiles-init.sh (v2)
# -----------------------------------------------------------------------------
# 3エージェント化の初期化スクリプト(冪等・再実行可)。
# docker compose up -d で hermes-agent が healthy になった後、ホストで1回実行する。
#
# v2 での変更点:
#   - profile create 直後は /run/service/gateway-<name> の s6 スロットが
#     未登録のことがあり、gateway start が非s6フォールバックに落ちて
#     起動に失敗する事象に対応。
#   - 手順を「全プロファイル作成 → .env 設定 → コンテナ再起動(ブート
#     リコンサイラがスロット登録) → gateway 起動」の順序に変更。
#   - 内側ループの変数名が外側の i を潰していた問題を修正。
#
# 実行後、ダッシュボード(http://<host>:31001)のプロファイルスイッチャーに
# default / alfa / bravo / charlie が現れ、1画面で3エージェントを管理できる。
# =============================================================================
set -euo pipefail

CONTAINER="${STACK_NAME:-inferlab}-hermes-agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_TEMPLATE_DIR="${SCRIPT_DIR}/hermes-agent/profiles"

# プロファイル名とAPIサーバーポートの対応(必要に応じて変更)
PROFILES=(alfa bravo charlie)
PORTS=(8643 8644 8645)

# wait_healthy は Hermes Agent コンテナが healthcheck に成功するまで待機する。
# 引数: なし。
# 戻り値: healthy になれば 0 を返し、タイムアウト時はエラーを出して終了する。
wait_healthy() {
  echo "==> ${CONTAINER} が healthy になるのを待機..."
  for _try in $(seq 1 30); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo unknown)"
    [ "${status}" = "healthy" ] && echo "    healthy" && return 0
    sleep 5
  done
  echo "ERROR: ${CONTAINER} が healthy になりません(status=${status})。" >&2
  exit 1
}

# copy_profile_template は Git 管理された profile テンプレートをコンテナ内へ同期する。
# 引数: profile 名。
# 戻り値: テンプレートのコピーに成功すれば 0 を返す。
copy_profile_template() {
  local profile="$1"
  local template_dir="${PROFILE_TEMPLATE_DIR}/${profile}"
  local profile_dir="/opt/data/profiles/${profile}"

  if [ ! -d "${template_dir}" ]; then
    echo "    template not found, skip"
    return 0
  fi

  echo "==> [${profile}] profile template を同期"
  docker exec "${CONTAINER}" mkdir -p "${profile_dir}"
  docker cp "${template_dir}/config.yaml" "${CONTAINER}:${profile_dir}/config.yaml"
  docker cp "${template_dir}/SOUL.md" "${CONTAINER}:${profile_dir}/SOUL.md"
}

echo "==> target container: ${CONTAINER}"
wait_healthy

# -----------------------------------------------------------------------------
# Phase 1: プロファイル作成と .env 設定(gateway はまだ起動しない)
# -----------------------------------------------------------------------------
for i in "${!PROFILES[@]}"; do
  profile="${PROFILES[$i]}"
  port="${PORTS[$i]}"
  env_file="/opt/data/profiles/${profile}/.env"

  echo "==> [${profile}] profile create (存在する場合はスキップ)"
  if ! docker exec "${CONTAINER}" hermes profile list 2>/dev/null | grep -qw "${profile}"; then
    docker exec "${CONTAINER}" hermes profile create "${profile}"
  else
    echo "    already exists, skip"
  fi

  echo "==> [${profile}] .env に API_SERVER_PORT=${port} を設定"
  docker exec "${CONTAINER}" sh -c "
    touch '${env_file}'
    if grep -q '^API_SERVER_PORT=' '${env_file}'; then
      sed -i 's/^API_SERVER_PORT=.*/API_SERVER_PORT=${port}/' '${env_file}'
    else
      {
        echo 'API_SERVER_ENABLED=true'
        echo 'API_SERVER_HOST=0.0.0.0'
        echo 'API_SERVER_PORT=${port}'
      } >> '${env_file}'
    fi

    # Discord bot は default gateway だけで接続するため、API 専用プロファイルでは親環境の token 継承を明示的に止める。
    for key in DISCORD_BOT_TOKEN DISCORD_ALLOWED_USERS DISCORD_ALLOWED_CHANNELS DISCORD_HOME_CHANNEL DISCORD_HOME_CHANNEL_NAME; do
      if grep -q \"^\${key}=\" '${env_file}'; then
        sed -i \"s|^\${key}=.*|\${key}=|\" '${env_file}'
      else
        echo \"\${key}=\" >> '${env_file}'
      fi
    done
  "

  copy_profile_template "${profile}"
done

# -----------------------------------------------------------------------------
# Phase 2: s6 スロット登録の確認。無ければコンテナ再起動で
#          ブートリコンサイラ(02-reconcile-profiles)に登録させる
# -----------------------------------------------------------------------------
need_restart=0
for profile in "${PROFILES[@]}"; do
  if ! docker exec "${CONTAINER}" test -d "/run/service/gateway-${profile}" 2>/dev/null; then
    echo "==> [${profile}] s6 スロット /run/service/gateway-${profile} が未登録"
    need_restart=1
  fi
done

if [ "${need_restart}" -eq 1 ]; then
  echo "==> コンテナを再起動してブートリコンサイラにスロットを登録させます"
  docker restart "${CONTAINER}" >/dev/null
  wait_healthy
  # 再起動直後は cont-init 完了までわずかにラグがあるため少し待つ
  sleep 5
fi

# -----------------------------------------------------------------------------
# Phase 3: gateway 起動とヘルスチェック
# -----------------------------------------------------------------------------
for i in "${!PROFILES[@]}"; do
  profile="${PROFILES[$i]}"
  port="${PORTS[$i]}"

  echo "==> [${profile}] gateway start"
  docker exec "${CONTAINER}" hermes -p "${profile}" gateway start || \
    docker exec "${CONTAINER}" hermes -p "${profile}" gateway restart || true

  echo "==> [${profile}] health check (:${port})"
  ok=0
  for _try in $(seq 1 15); do
    if docker exec "${CONTAINER}" curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "    OK"
      ok=1
      break
    fi
    sleep 2
  done
  if [ "${ok}" -eq 0 ]; then
    echo "    WARN: :${port} が応答しません。ログを確認してください:"
    echo "      docker exec ${CONTAINER} tail -n 50 /opt/data/logs/gateways/${profile}/current"
    echo "      docker exec ${CONTAINER} /command/s6-svstat /run/service/gateway-${profile}"
  fi
done

echo ""
echo "==> 完了。状態確認:"
docker exec "${CONTAINER}" hermes gateway status || true
for profile in "${PROFILES[@]}"; do
  docker exec "${CONTAINER}" hermes -p "${profile}" gateway status || true
done

cat <<'EOF'

--- 次のステップ ---
* ダッシュボード: http://<PUBLIC_HOST>:31001 (プロファイルスイッチャーで切替)
* 各プロファイルの初期設定(モデル・SOUL等):
    docker exec -it <container> hermes -p alfa setup
    docker exec -it <container> hermes -p bravo setup
    docker exec -it <container> hermes -p charlie setup
* Open WebUI からの接続先(internal-nw 内):
    alfa   : http://hermes-agent:8643/v1
    bravo  : http://hermes-agent:8644/v1
    charlie: http://hermes-agent:8645/v1
EOF
