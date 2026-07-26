#!/usr/bin/env bash
set -euo pipefail

# repository rootから実行する。
HARBOR_COMPOSE_FILE="${HARBOR_COMPOSE_FILE:-30-developer/harbor/generated/docker-compose.yml}"
HARBOR_OVERRIDE_FILE="${HARBOR_OVERRIDE_FILE:-30-developer/harbor/docker-compose.override.yml}"

if [ ! -f "$HARBOR_COMPOSE_FILE" ]; then
  echo "ERROR: $HARBOR_COMPOSE_FILE が見つかりません。" >&2
  echo "ERROR: 先に 30-developer/scripts/prepare-harbor-compose.sh を実行してください。" >&2
  exit 1
fi

if [ ! -f "$HARBOR_OVERRIDE_FILE" ]; then
  echo "ERROR: $HARBOR_OVERRIDE_FILE が見つかりません。" >&2
  exit 1
fi

if [ -z "${STACK_NAME:-}" ] && [ -f .env ]; then
  STACK_NAME="$(awk -F= '$1 == "STACK_NAME" { gsub(/"/, "", $2); print $2; exit }' .env)"
fi
STACK_NAME="${STACK_NAME:-inferlab}"

# root composeにHarbor生成composeとoverrideを追記する形で実行する。
exec docker compose \
  -p "$STACK_NAME" \
  -f docker-compose.yml \
  -f "$HARBOR_COMPOSE_FILE" \
  -f "$HARBOR_OVERRIDE_FILE" \
  --env-file .env \
  "$@"
