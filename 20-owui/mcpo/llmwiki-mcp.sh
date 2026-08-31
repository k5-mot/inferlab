#!/bin/sh

set -eu

# mcpoの標準入出力を、稼働中のllmwiki MCPプロセスへそのまま接続する。
exec docker exec -i "${LLMWIKI_CONTAINER_NAME:?LLMWIKI_CONTAINER_NAME is required}" \
    node /app/dist/serve.js
