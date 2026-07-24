#!/usr/bin/env bash
set -euo pipefail

INTERFACE="${1:-}"
ACTION="${2:-}"
SERVICE="inferlab-docker-egress-enp3s0.service"

# enp3s0の再接続後だけ経路を再生成し、通常のNetworkManagerイベントには介入しない。
if [[ "${INTERFACE}" != "enp3s0" ]]; then
  exit 0
fi

case "${ACTION}" in
  up|dhcp4-change)
    logger -t inferlab-docker-egress \
      "${INTERFACE} ${ACTION}: ${SERVICE}を再適用します"
    systemctl --no-block restart "${SERVICE}"
    ;;
esac
