#!/usr/bin/env bash
set -euo pipefail

cd /opt/hermes

# 現行imageにLangfuse連携packageが同梱されない環境があるため、起動直前に補完する。
# 既に解決済みの場合は何もしないため、再起動時の副作用は最小限になる。
uv add "langfuse==4.14.1" || true

exec /init /opt/hermes/docker/main-wrapper.sh gateway run
