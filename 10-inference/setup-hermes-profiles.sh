#!/usr/bin/env bash
# =============================================================================
# hermes-profiles-init.sh
# -----------------------------------------------------------------------------
# 3エージェント化の初期化スクリプト(冪等・再実行可)。
# docker compose up -d で hermes-agent が healthy になった後、ホストで1回実行する。
#
#   1. alfa / bravo / charlie プロファイルを作成
#      → コンテナ内の s6 に /run/service/gateway-<name>/ が動的登録される
#   2. 各プロファイル自身の .env に API_SERVER_PORT を書き込む
#      (コンテナ全体の environment: に書くと全プロファイルが衝突するため)
#   3. 各プロファイルの gateway を起動
#      → 以後はコンテナ再起動時も s6 の状態永続化により自動復帰する
#
# 実行後、ダッシュボード(http://<host>:31001)のプロファイルスイッチャーに
# default / alfa / bravo / charlie が現れ、1画面で3エージェントを管理できる。
# =============================================================================
set -euo pipefail

CONTAINER="${STACK_NAME:-inferlab}-hermes-agent"

# プロファイル名とAPIサーバーポートの対応(必要に応じて変更)
# ※連想配列だと処理順が不定になるため、順序保証のある通常配列を使用
PROFILES=(alfa bravo charlie)
PORTS=(8643 8644 8645)

echo "==> target container: ${CONTAINER}"
docker inspect --format '{{.State.Health.Status}}' "${CONTAINER}" \
  | grep -q healthy || {
    echo "ERROR: ${CONTAINER} が healthy ではありません。先に docker compose up -d を完了させてください。" >&2
    exit 1
  }

for i in "${!PROFILES[@]}"; do
  profile="${PROFILES[$i]}"
  port="${PORTS[$i]}"
  env_file="/opt/data/profiles/${profile}/.env"

  echo "==> [${profile}] profile create (存在する場合はスキップ)"
  if ! docker exec "${CONTAINER}" hermes profile list 2>/dev/null | grep -qw "${profile}"; then
    # docker exec は自動で hermes ユーザーに降格するため所有権は正しく書かれる
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

  echo "==> [${profile}] gateway (re)start"
  docker exec "${CONTAINER}" hermes -p "${profile}" gateway restart \
    || docker exec "${CONTAINER}" hermes -p "${profile}" gateway start

  echo "==> [${profile}] health check (:${port})"
  for i in $(seq 1 15); do
    if docker exec "${CONTAINER}" curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "    OK"
      break
    fi
    [ "$i" -eq 15 ] && echo "    WARN: :${port} がまだ応答しません。ログを確認してください:" \
      && echo "    docker exec ${CONTAINER} tail -n 50 /opt/data/logs/gateways/${profile}/current"
    sleep 2
  done
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
