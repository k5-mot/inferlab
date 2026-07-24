#!/usr/bin/env bash
set -euo pipefail

GATEWAY="${GATEWAY:-192.168.1.1}"
TABLE="${TABLE:-103}"
DEV="${DEV:-enp3s0}"
HOST_DEV="${HOST_DEV:-bridge0}"
HOST_RULE_PRIORITY="${HOST_RULE_PRIORITY:-10300}"
RULE_PRIORITY_BASE="${RULE_PRIORITY_BASE:-10321}"
DOCKER_SUBNETS="${DOCKER_SUBNETS:-172.21.0.0/16 172.22.0.0/16}"

host_src_ip="$(ip -4 -o addr show dev "${HOST_DEV}" scope global | awk 'NR == 1 {split($4, addr, "/"); print addr[1]}')"
dev_link_route="$(ip -4 route show dev "${DEV}" scope link | awk 'NR == 1 {print $1}')"
dev_src_ip="$(ip -4 -o addr show dev "${DEV}" scope global | awk 'NR == 1 {split($4, addr, "/"); print addr[1]}')"

if [[ -z "${host_src_ip}" ]]; then
  echo "ERROR: ${HOST_DEV} has no global IPv4 address" >&2
  exit 1
fi

if [[ -z "${dev_link_route}" || -z "${dev_src_ip}" ]]; then
  echo "ERROR: ${DEV} has no global IPv4 address or link route" >&2
  exit 1
fi

if [[ "${dev_src_ip}" == "${host_src_ip}" ]]; then
  echo "ERROR: ${DEV} and ${HOST_DEV} have the same IPv4 address: ${dev_src_ip}" >&2
  exit 1
fi

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
ip route replace "${dev_link_route}" dev "${DEV}" src "${dev_src_ip}" table "${TABLE}"
ip rule del from "${dev_src_ip}/32" table "${TABLE}" priority "${HOST_RULE_PRIORITY}" 2>/dev/null || true
ip rule add from "${dev_src_ip}/32" table "${TABLE}" priority "${HOST_RULE_PRIORITY}"
ip route replace default via "${GATEWAY}" dev "${DEV}" table "${TABLE}"

read -r -a subnet_list <<< "${DOCKER_SUBNETS}"
priority="${RULE_PRIORITY_BASE}"
ufw_active=false
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active$'; then
  ufw_active=true
fi

for subnet in "${subnet_list[@]}"; do
  bridge_dev="$(ip -4 route show "${subnet}" | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"

  ip rule del from "${subnet}" table "${TABLE}" priority "${priority}" 2>/dev/null || true
  ip rule add from "${subnet}" table "${TABLE}" priority "${priority}"

  while iptables -t nat -D POSTROUTING -s "${subnet}" -o "${DEV}" -j MASQUERADE 2>/dev/null; do
    true
  done
  iptables -t nat -I POSTROUTING 1 -s "${subnet}" -o "${DEV}" -j MASQUERADE

  if [[ -n "${bridge_dev}" ]]; then
    # Docker bridgeからenp3s0へ出るforwardをDocker標準チェーンに依存せず明示する。
    while iptables -D FORWARD -i "${bridge_dev}" -o "${DEV}" -j ACCEPT 2>/dev/null; do
      true
    done
    while iptables -D FORWARD -i "${DEV}" -o "${bridge_dev}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
      true
    done
    iptables -I FORWARD 1 -i "${DEV}" -o "${bridge_dev}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -I FORWARD 1 -i "${bridge_dev}" -o "${DEV}" -j ACCEPT

    if [[ "${ufw_active}" == true ]]; then
      # UFWのforward既定拒否を維持したまま、対象Docker subnetの外向き通信だけを許可する。
      ufw route allow in on "${bridge_dev}" out on "${DEV}" from "${subnet}" to any
    fi
  fi

  priority=$((priority + 1))
done
