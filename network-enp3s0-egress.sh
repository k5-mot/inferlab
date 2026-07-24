#!/usr/bin/env bash
set -euo pipefail

HOST_DEV="${HOST_DEV:-bridge0}"
HOST_NIC="${HOST_NIC:-enp2s0}"
DOCKER_DEV="${DOCKER_DEV:-enp3s0}"
DOCKER_CONN="${DOCKER_CONN:-docker-enp3s0}"
LEGACY_DOCKER_CONN="${LEGACY_DOCKER_CONN:-Wired connection 2}"
EGRESS_SCRIPT="${EGRESS_SCRIPT:-script/inferlab-docker-egress-enp3s0.sh}"
EGRESS_SERVICE="${EGRESS_SERVICE:-script/inferlab-docker-egress-enp3s0.service}"
DOCKER_NETWORK="${DOCKER_NETWORK:-inferlab_internal-nw}"
KEYCLOAK_NETWORK="${KEYCLOAK_NETWORK:-inferlab_keycloak-nw}"
TABLE="${TABLE:-103}"
HOST_RULE_PRIORITY="${HOST_RULE_PRIORITY:-10300}"
RULE_PRIORITY_BASE="${RULE_PRIORITY_BASE:-10321}"
DOCKER_SUBNETS="${DOCKER_SUBNETS:-172.21.0.0/16 172.22.0.0/16}"

# usage は、このスクリプトの使い方を表示する。
# 引数: なし。
# 戻り値: なし。
usage() {
  cat <<'USAGE'
Usage:
  ./network-enp3s0-egress.sh status
  sudo ./network-enp3s0-egress.sh prepare
  sudo ./network-enp3s0-egress.sh up
  sudo ./network-enp3s0-egress.sh apply
  sudo ./network-enp3s0-egress.sh verify
  sudo ./network-enp3s0-egress.sh diagnose
  sudo ./network-enp3s0-egress.sh install-service
  sudo ./network-enp3s0-egress.sh rollback

Flow:
  1. ./network-enp3s0-egress.sh status
  2. sudo ./network-enp3s0-egress.sh prepare
  3. enp3s0 にLANケーブルを挿す
  4. sudo ./network-enp3s0-egress.sh up
  5. sudo ./network-enp3s0-egress.sh apply
  6. sudo ./network-enp3s0-egress.sh verify
  7. sudo ./network-enp3s0-egress.sh install-service
USAGE
}

# require_root は、root権限が必要なサブコマンドを誤実行しないようにする。
# 引数: なし。
# 戻り値: rootなら0、rootでなければ終了コード1で終了する。
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: このサブコマンドは sudo で実行してください。" >&2
    exit 1
  fi
}

# connection_exists は、NetworkManager接続プロファイルの存在を判定する。
# 引数: $1 に確認する接続名を指定する。
# 戻り値: 接続が存在すれば0、存在しなければ1。
connection_exists() {
  local name="$1"
  nmcli -t -f NAME connection show | grep -Fxq "${name}"
}

# print_section は、ログを読みやすくするための見出しを表示する。
# 引数: $1 に見出し名を指定する。
# 戻り値: なし。
print_section() {
  local title="$1"
  printf '\n===== %s =====\n' "${title}"
}

# host_ip は、ホスト管理bridgeのIPv4アドレスを返す。
# 引数: なし。
# 戻り値: IPv4アドレスを標準出力へ出力し、取得できた場合は0。
host_ip() {
  ip -4 -o addr show dev "${HOST_DEV}" scope global | awk 'NR == 1 {split($4, addr, "/"); print addr[1]}'
}

# docker_dev_ip は、Docker用NICのIPv4アドレスを返す。
# 引数: なし。
# 戻り値: IPv4アドレスを標準出力へ出力し、取得できた場合は0。
docker_dev_ip() {
  ip -4 -o addr show dev "${DOCKER_DEV}" scope global | awk 'NR == 1 {split($4, addr, "/"); print addr[1]}'
}

# docker_bridge_name は、Docker network IDからLinux bridge名を返す。
# 引数: $1 にDocker network名を指定する。
# 戻り値: bridge名を標準出力へ出力し、取得できた場合は0。
docker_bridge_name() {
  local network="$1"
  local network_id
  network_id="$(docker network inspect "${network}" --format '{{.Id}}')"
  printf 'br-%s\n' "${network_id:0:12}"
}

# run_status は、現在のNIC、経路、NetworkManager、Docker状態を表示する。
# 引数: なし。
# 戻り値: 主要コマンドが実行できれば0。権限不足の詳細確認は警告だけ表示する。
run_status() {
  print_section "link"
  ip -br link

  print_section "addr"
  ip -br addr

  print_section "route"
  ip route

  print_section "rule"
  ip rule

  print_section "table ${TABLE}"
  ip route show table "${TABLE}" || true

  print_section "bridge link"
  bridge link || true

  print_section "nmcli connections"
  nmcli -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT connection show || true

  print_section "nmcli devices"
  nmcli device status || true

  print_section "docker networks"
  docker network inspect "${DOCKER_NETWORK}" "${KEYCLOAK_NETWORK}" --format '{{.Name}} {{.Id}} {{json .IPAM.Config}}' || true

  print_section "docker containers"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}' || true

  print_section "cloudflare logs"
  docker logs --since 10m --tail 120 inferlab-cloudflare || true
}

# run_prepare は、enp3s0用NetworkManager接続をDocker専用に準備する。
# 引数: なし。
# 戻り値: 設定変更に成功すれば0。
# 副作用: NetworkManagerのenp3s0接続プロファイルを変更する。
run_prepare() {
  require_root

  local source_conn="${DOCKER_CONN}"
  if ! connection_exists "${source_conn}"; then
    source_conn="${LEGACY_DOCKER_CONN}"
  fi

  if ! connection_exists "${source_conn}"; then
    echo "ERROR: ${DOCKER_CONN} も ${LEGACY_DOCKER_CONN} も見つかりません。" >&2
    exit 1
  fi

  nmcli connection modify "${source_conn}" \
    connection.id "${DOCKER_CONN}" \
    connection.interface-name "${DOCKER_DEV}" \
    connection.master "" \
    connection.slave-type "" \
    ipv4.method auto \
    ipv4.never-default yes \
    ipv4.route-metric 900 \
    ipv4.dhcp-client-id mac \
    ipv6.method ignore \
    ipv6.never-default yes

  nmcli connection down "${DOCKER_CONN}" || true

  print_section "prepared connection"
  nmcli -f connection.id,connection.interface-name,connection.master,connection.slave-type,ipv4.method,ipv4.never-default,ipv4.dhcp-client-id connection show "${DOCKER_CONN}"

  print_section "bridge link"
  bridge link || true
}

# run_up は、enp3s0のDocker用接続を起動してDHCPアドレスを取得する。
# 引数: なし。
# 戻り値: 接続起動と前提検査に成功すれば0。
# 副作用: enp3s0のNetworkManager接続を起動する。
run_up() {
  require_root

  nmcli connection up "${DOCKER_CONN}"

  local hip dip
  hip="$(host_ip)"
  dip="$(docker_dev_ip)"

  print_section "addresses"
  ip -4 -br addr show dev "${HOST_DEV}"
  ip -4 -br addr show dev "${DOCKER_DEV}"

  if [[ -z "${hip}" || -z "${dip}" ]]; then
    echo "ERROR: ${HOST_DEV} または ${DOCKER_DEV} のIPv4アドレスを取得できません。" >&2
    exit 1
  fi

  if [[ "${hip}" == "${dip}" ]]; then
    echo "ERROR: ${HOST_DEV} と ${DOCKER_DEV} のIPv4アドレスが重複しています: ${hip}" >&2
    exit 1
  fi

  print_section "route"
  ip route

  if ip route | grep -Eq "^default .* dev ${DOCKER_DEV}( |$)"; then
    echo "ERROR: main tableに${DOCKER_DEV}経由のdefault routeがあります。" >&2
    exit 1
  fi
}

# run_apply は、Docker由来の外向き通信をenp3s0へ流す設定を適用する。
# 引数: なし。
# 戻り値: egress設定の適用に成功すれば0。
# 副作用: sysctl、ip rule、table 103、iptables、UFWの転送設定を変更する。
run_apply() {
  require_root

  if [[ ! -x "${EGRESS_SCRIPT}" ]]; then
    echo "ERROR: ${EGRESS_SCRIPT} が実行可能ではありません。" >&2
    exit 1
  fi

  GATEWAY="${GATEWAY:-192.168.1.1}" \
  TABLE="${TABLE}" \
  DEV="${DOCKER_DEV}" \
  HOST_DEV="${HOST_DEV}" \
  HOST_RULE_PRIORITY="${HOST_RULE_PRIORITY}" \
  RULE_PRIORITY_BASE="${RULE_PRIORITY_BASE}" \
  DOCKER_SUBNETS="${DOCKER_SUBNETS}" \
    "${EGRESS_SCRIPT}"

  run_verify
}

# run_verify は、ホスト、Docker、Cloudflare tunnelの疎通状態を確認する。
# 引数: なし。
# 戻り値: 確認コマンドがすべて成功すれば0。
run_verify() {
  local hip dip docker_br
  hip="$(host_ip)"
  dip="$(docker_dev_ip)"
  docker_br="$(docker_bridge_name "${DOCKER_NETWORK}")"

  print_section "policy routing"
  ip rule
  ip route show table "${TABLE}" || true
  ip route get 1.1.1.1 from "${hip}"
  if [[ -n "${dip}" ]]; then
    ip route get 1.1.1.1 from "${dip}"
  fi
  ip route get 1.1.1.1 from 172.21.0.10 iif "${docker_br}" || true
  ip route get 172.21.0.30 from 172.21.0.1 || true

  print_section "nat"
  iptables -t nat -S POSTROUTING | grep "${DOCKER_DEV}" || true

  print_section "forward"
  iptables -S FORWARD | grep "${DOCKER_DEV}" || true

  print_section "ufw route"
  if command -v ufw >/dev/null 2>&1; then
    LC_ALL=C ufw status | grep -E "^(Status:|.*${DOCKER_DEV}.*)$" || true
  else
    echo "ufw is not installed"
  fi

  print_section "host connectivity"
  ping -c 3 192.168.1.1
  ping -c 3 1.1.1.1
  resolvectl query example.com
  curl -4I --max-time 10 https://example.com

  print_section "docker connectivity"
  docker run --rm --network "${DOCKER_NETWORK}" curlimages/curl:latest \
    sh -c 'ip route; getent hosts example.com; curl -4I --max-time 10 https://example.com'
  docker run --rm --network "${DOCKER_NETWORK}" curlimages/curl:latest \
    sh -c 'curl -4 --max-time 10 https://1.1.1.1/cdn-cgi/trace | head'

  print_section "cloudflare"
  docker ps --format 'table {{.Names}}\t{{.Status}}' | grep inferlab-cloudflare
  docker logs --since 10m --tail 120 inferlab-cloudflare
}

# run_install_service は、egress設定をsystemd oneshot serviceとして永続化する。
# 引数: なし。
# 戻り値: 配置と有効化に成功すれば0。
# 副作用: /usr/local/sbin と /etc/systemd/system にファイルを配置し、systemd unitを有効化する。
run_install_service() {
  require_root

  install -m 0755 "${EGRESS_SCRIPT}" /usr/local/sbin/inferlab-docker-egress-enp3s0.sh
  install -m 0644 "${EGRESS_SERVICE}" /etc/systemd/system/inferlab-docker-egress-enp3s0.service
  systemctl daemon-reload
  systemctl enable --now inferlab-docker-egress-enp3s0.service
  systemctl status inferlab-docker-egress-enp3s0.service --no-pager
}

# run_diagnose は、Docker通信が停止する箇所をiptablesカウンタと短時間のpacket captureで調査する。
# 引数: なし。
# 戻り値: 診断を最後まで実行できれば0。個別の疎通失敗は診断結果として扱い、終了を継続する。
# 副作用: 一時ファイルを作成し、診断用Dockerコンテナとtcpdumpを最大25秒間実行する。
run_diagnose() {
  require_root

  local docker_br capture_dir bridge_capture egress_capture bridge_pid egress_pid
  docker_br="$(docker_bridge_name "${DOCKER_NETWORK}")"
  capture_dir="$(mktemp -d /tmp/inferlab-network-diagnose.XXXXXX)"
  bridge_capture="${capture_dir}/docker-bridge.log"
  egress_capture="${capture_dir}/enp3s0.log"

  print_section "diagnostic context"
  date --iso-8601=seconds
  ip -4 -br addr show dev "${HOST_DEV}"
  ip -4 -br addr show dev "${DOCKER_DEV}"
  ip rule
  ip route show table "${TABLE}" || true
  ip neigh show dev "${DOCKER_DEV}"
  sysctl net.ipv4.ip_forward \
    net.ipv4.conf.all.rp_filter \
    "net.ipv4.conf.${DOCKER_DEV}.rp_filter" \
    "net.ipv4.conf.${docker_br}.rp_filter"

  print_section "firewall before test"
  iptables -nvL FORWARD --line-numbers
  iptables -t nat -nvL POSTROUTING --line-numbers
  iptables -nvL DOCKER-USER --line-numbers || true
  if command -v ufw >/dev/null 2>&1; then
    LC_ALL=C ufw status verbose || true
  fi

  if command -v tcpdump >/dev/null 2>&1; then
    timeout 25 tcpdump -l -nn -i "${docker_br}" '(host 1.1.1.1 or port 53)' >"${bridge_capture}" 2>&1 &
    bridge_pid=$!
    timeout 25 tcpdump -l -nn -i "${DOCKER_DEV}" '(host 1.1.1.1 or port 53)' >"${egress_capture}" 2>&1 &
    egress_pid=$!
    sleep 1
  else
    bridge_pid=""
    egress_pid=""
    echo "WARN: tcpdumpがないためpacket captureを省略します。" >&2
  fi

  print_section "docker test"
  docker run --rm --pull never --network "${DOCKER_NETWORK}" curlimages/curl:latest \
    sh -c 'cat /etc/resolv.conf; curl -4 --max-time 5 https://1.1.1.1/cdn-cgi/trace | head || true; getent ahostsv4 example.com || true'

  if [[ -n "${bridge_pid}" ]]; then
    wait "${bridge_pid}" || true
    wait "${egress_pid}" || true

    print_section "docker bridge capture"
    cat "${bridge_capture}"

    print_section "enp3s0 capture"
    cat "${egress_capture}"
  fi

  print_section "firewall after test"
  iptables -nvL FORWARD --line-numbers
  iptables -t nat -nvL POSTROUTING --line-numbers
  iptables -nvL DOCKER-USER --line-numbers || true

  rm -f -- "${bridge_capture}" "${egress_capture}"
  rmdir -- "${capture_dir}"
}

# run_rollback は、Docker egress分離のランタイム設定を削除する。
# 引数: なし。
# 戻り値: 削除処理を完了すれば0。
# 副作用: systemd service、ip rule、table 103、iptables、UFWの追加ルール、docker-enp3s0接続を停止する。
run_rollback() {
  require_root

  systemctl disable --now inferlab-docker-egress-enp3s0.service 2>/dev/null || true
  ip rule del priority "${HOST_RULE_PRIORITY}" 2>/dev/null || true
  ip rule del priority "${RULE_PRIORITY_BASE}" 2>/dev/null || true
  ip rule del priority "$((RULE_PRIORITY_BASE + 1))" 2>/dev/null || true
  ip route flush table "${TABLE}" || true

  read -r -a subnet_list <<< "${DOCKER_SUBNETS}"
  for subnet in "${subnet_list[@]}"; do
    bridge_dev="$(ip -4 route show "${subnet}" | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    while iptables -t nat -D POSTROUTING -s "${subnet}" -o "${DOCKER_DEV}" -j MASQUERADE 2>/dev/null; do
      true
    done
    if [[ -n "${bridge_dev}" ]]; then
      while iptables -D FORWARD -i "${bridge_dev}" -o "${DOCKER_DEV}" -j ACCEPT 2>/dev/null; do
        true
      done
      while iptables -D FORWARD -i "${DOCKER_DEV}" -o "${bridge_dev}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
        true
      done
      if command -v ufw >/dev/null 2>&1; then
        ufw --force route delete allow in on "${bridge_dev}" out on "${DOCKER_DEV}" from "${subnet}" to any || true
      fi
    fi
  done

  nmcli connection down "${DOCKER_CONN}" || true

  run_status
}

# main は、サブコマンドを解釈して対応する処理を実行する。
# 引数: $@ にサブコマンドと将来拡張用の引数を受け取る。
# 戻り値: サブコマンドの終了コードを返す。不明なサブコマンドでは2で終了する。
main() {
  local command="${1:-}"
  case "${command}" in
    status)
      run_status
      ;;
    prepare)
      run_prepare
      ;;
    up)
      run_up
      ;;
    apply)
      run_apply
      ;;
    verify)
      run_verify
      ;;
    diagnose)
      run_diagnose
      ;;
    install-service)
      run_install_service
      ;;
    rollback)
      run_rollback
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      usage >&2
      echo "ERROR: unknown command: ${command}" >&2
      exit 2
      ;;
  esac
}

main "$@"
