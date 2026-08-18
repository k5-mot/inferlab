#!/usr/bin/env bash

set -Eeuo pipefail

# 第1引数を実行コマンドとして取得.
# (up/down/...)
COMMAND="${1:-}"

# up時、上のprofileから順に起動.
# down時、下のprofileから順に停止.
readonly PROFILES=(
  "common"
  "keycloak"
  "pubnet"
  "inference"
  "rag"
#   "registry"
  "owui"
#   "dify"
  "nextcloud"
#   "bookstack"
#   "kaneo"
#   "zulip"
  "obsidian"
#   "gitlab"
  "o11y"
  "langfuse"
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
  up-full)
    for profile in "${PROFILES[@]}"; do
        profile_args+=(--profile "$profile")
    done
    docker compose "${profile_args[@]}" up -d "$@"
    ;;
  down-full)
    for profile in "${PROFILES[@]}"; do
        profile_args+=(--profile "$profile")
    done
    docker compose "${profile_args[@]}" down "$@"
    ;;
  exec | logs | ps)
    for profile in "${PROFILES[@]}"; do
        profile_args+=(--profile "$profile")
    done
    docker compose "${profile_args[@]}" "$COMMAND" "$@"
    ;;
  *)
    echo "Usage: $0 {up|down} [docker compose options...]"
    echo
    echo "Examples:"
    echo "  $0 up"
    echo "  $0 up -d --build --force-recreate --remove-orphans"
    echo "  $0 down"
    echo "  $0 down --remove-orphans"
    echo "  $0 exec -it <service> bash"
    echo "  $0 logs"
    echo "  $0 logs -f <service>"
    echo "  $0 logs --tail=100 <service>"
    echo "  $0 ps"
    echo "  $0 ps --all"
    exit 1
    ;;
esac
