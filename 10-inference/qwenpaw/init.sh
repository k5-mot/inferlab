#!/usr/bin/env bash
set -euo pipefail

# 公式初期化でversion固有のschemaとbuiltin skillを生成する。
if [[ ! -f "${QWENPAW_WORKING_DIR}/config.json" ]]; then
  qwenpaw init --defaults --accept-security
fi

python /opt/inferlab/configure.py
