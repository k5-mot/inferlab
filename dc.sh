#!/usr/bin/env bash

set -Eeuo pipefail

# 第1引数を実行コマンドとして取得.
# (up/down/...)
COMMAND="${1:-}"

# up時、上のprofileから順に起動.
# down時、下のprofileから順に停止.
readonly PROFILES=(
  "common"
  "infra"
  "inference"
  "webui"
  "storage"
#   "automation"
#   "team-chat"
#   "team-project"
#   "team-wiki"
  "llmops"
)

# COMMANDを除く残りの引数をdocker-composeのオプションとして渡す.
if [[ $# -gt 0 ]]; then
  shift
fi

case "$COMMAND" in
  up)
    for profile in "${PROFILES[@]}"; do
      echo "==> Starting profile: ${profile}"
      docker compose --profile "$profile" up -d "$@"
    done
    ;;
  down)
    for ((i = ${#PROFILES[@]} - 1; i >= 0; i--)); do
      profile="${PROFILES[$i]}"
      echo "==> Stopping profile: ${profile}"
      docker compose --profile "$profile" down "$@"
    done
    ;;
  *)
    echo "Usage: $0 {up|down} [docker compose options...]"
    echo
    echo "Examples:"
    echo "  $0 up"
    echo "  $0 up --build"
    echo "  $0 down"
    exit 1
    ;;
esac
