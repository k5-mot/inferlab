#!/usr/bin/env bash
set -euo pipefail

GATEWAY="${GATEWAY:-192.168.1.1}"
TABLE="${TABLE:-103}"
DEV="${DEV:-enp3s0}"
HOST_DEV="${HOST_DEV:-bridge0}"
RULE_PRIORITY_BASE="${RULE_PRIORITY_BASE:-10321}"
DOCKER_SUBNETS="${DOCKER_SUBNETS:-172.21.0.0/16 172.22.0.0/16}"

# 同一LAN上の2NIC構成でARP応答と戻り経路検査が揺れないようにする。
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.arp_filter=1 >/dev/null
sysctl -w "net.ipv4.conf.${HOST_DEV}.arp_ignore=1" >/dev/null
sysctl -w "net.ipv4.conf.${HOST_DEV}.arp_announce=2" >/dev/null
sysctl -w "net.ipv4.conf.${HOST_DEV}.rp_filter=2" >/dev/null
sysctl -w "net.ipv4.conf.${DEV}.arp_ignore=1" >/dev/null
sysctl -w "net.ipv4.conf.${DEV}.arp_announce=2" >/dev/null
sysctl -w "net.ipv4.conf.${DEV}.rp_filter=2" >/dev/null

# Docker由来の通信だけをenp3s0へ逃がすため、通常のdefault routeは変更しない。
ip route replace default via "${GATEWAY}" dev "${DEV}" table "${TABLE}"

read -r -a subnet_list <<< "${DOCKER_SUBNETS}"
priority="${RULE_PRIORITY_BASE}"
for subnet in "${subnet_list[@]}"; do
  ip rule del from "${subnet}" table "${TABLE}" priority "${priority}" 2>/dev/null || true
  ip rule add from "${subnet}" table "${TABLE}" priority "${priority}"
  iptables -t nat -C POSTROUTING -s "${subnet}" -o "${DEV}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${subnet}" -o "${DEV}" -j MASQUERADE
  priority=$((priority + 1))
done
