#!/usr/bin/env bash
set -euo pipefail

HOST_DEV="${HOST_DEV:-bridge0}"
HOST_NIC="${HOST_NIC:-enp2s0}"
HOST_CONN="${HOST_CONN:-bridge0}"
DOCKER_DEV="${DOCKER_DEV:-enp3s0}"
DOCKER_CONN="${DOCKER_CONN:-docker-enp3s0}"
LEGACY_DOCKER_CONN="${LEGACY_DOCKER_CONN:-Wired connection 2}"
EGRESS_SCRIPT="${EGRESS_SCRIPT:-script/inferlab-docker-egress-enp3s0.sh}"
EGRESS_SERVICE="${EGRESS_SERVICE:-script/inferlab-docker-egress-enp3s0.service}"
EGRESS_DISPATCHER="${EGRESS_DISPATCHER:-script/inferlab-docker-egress-enp3s0-dispatcher.sh}"
EGRESS_DISPATCHER_TARGET="${EGRESS_DISPATCHER_TARGET:-/etc/NetworkManager/dispatcher.d/90-inferlab-docker-egress-enp3s0}"
DOCKER_NETWORK="${DOCKER_NETWORK:-inferlab_internal-nw}"
KEYCLOAK_NETWORK="${KEYCLOAK_NETWORK:-inferlab_keycloak-nw}"
TABLE="${TABLE:-103}"
HOST_RULE_PRIORITY="${HOST_RULE_PRIORITY:-10300}"
RULE_PRIORITY_BASE="${RULE_PRIORITY_BASE:-10321}"
DOCKER_SUBNETS="${DOCKER_SUBNETS:-172.21.0.0/16 172.22.0.0/16}"
STACK_NAME="${STACK_NAME:-inferlab}"
GATEWAY_IP="${GATEWAY_IP:-192.168.1.1}"
PRIMARY_BRIDGE="${PRIMARY_BRIDGE:-${HOST_DEV}}"
PRIMARY_NIC="${PRIMARY_NIC:-${HOST_NIC}}"
JOURNAL_LINES="${JOURNAL_LINES:-4000}"
DOCKER_LOG_LINES="${DOCKER_LOG_LINES:-1200}"
DOCKER_SINCE="${DOCKER_SINCE:-6h}"
COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-45s}"
OUTPUT_ROOT="${OUTPUT_ROOT:-logs}"
RUN_ID="$(date '+%Y%m%d-%H%M%S-%Z')"
OUT_DIR=""
RAW_DIR=""
REPORT=""
COMMAND=""

# usage は、このスクリプトの使い方を表示する。
# 引数: なし。
# 戻り値: なし。
usage() {
  cat <<'USAGE'
Usage:
  sudo ./nwchk.sh [--output-dir DIR] [triage]
  ./nwchk.sh [--output-dir DIR] status
  sudo ./nwchk.sh [--output-dir DIR] prepare
  sudo ./nwchk.sh [--output-dir DIR] up
  sudo ./nwchk.sh [--output-dir DIR] apply
  sudo ./nwchk.sh [--output-dir DIR] verify
  sudo ./nwchk.sh [--output-dir DIR] diagnose
  sudo ./nwchk.sh [--output-dir DIR] pin-host-mac
  sudo ./nwchk.sh [--output-dir DIR] unpin-host-mac
  sudo ./nwchk.sh [--output-dir DIR] install-service
  sudo ./nwchk.sh [--output-dir DIR] rollback

Options:
  -o, --output-dir DIR  診断ログの保存先。既定値は logs/
  -h, --help            このヘルプを表示する

Flow:
  1. ./nwchk.sh status
  2. sudo ./nwchk.sh prepare
  3. enp3s0 にLANケーブルを挿す
  4. sudo ./nwchk.sh up
  5. sudo ./nwchk.sh apply
  6. sudo ./nwchk.sh verify
  7. sudo ./nwchk.sh install-service

Incident:
  1. 再起動前に sudo ./nwchk.sh triage
  2. Dockerだけ疎通しない場合は sudo ./nwchk.sh diagnose

Host bridge MAC:
  1. sudo ./nwchk.sh pin-host-mac
  2. ローカルコンソールを確保して sudo reboot
  3. ./nwchk.sh status
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

# initialize_output_paths は、今回の診断ログを保存するdirectoryを初期化する。
# 引数: なし。OUTPUT_ROOTとRUN_IDを使用する。
# 戻り値: directoryを作成できれば0。
# 副作用: OUTPUT_ROOT配下に日時directoryとraw directoryを作成する。
initialize_output_paths() {
  OUT_DIR="${OUTPUT_ROOT%/}/${RUN_ID}"
  RAW_DIR="${OUT_DIR}/raw"
  REPORT="${OUT_DIR}/NETWORK_TRIAGE.md"
  mkdir -p "${RAW_DIR}"
}

# redact は、Codexへ渡すログに認証情報が混ざるリスクを下げる。
# 引数: なし。標準入力からログ本文を受け取る。
# 戻り値: sedの終了コードを返す。
redact() {
  sed -E \
    -e 's/((TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|PRIVATE[_-]?KEY|ACCESS[_-]?KEY|CLIENT[_-]?SECRET|AUTHORIZATION)[A-Za-z0-9_ -]*[:=][[:space:]]*)[^[:space:]"'"'"']+/\1[REDACTED]/Ig' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/Ig' \
    -e 's/(Basic )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/Ig' \
    -e 's/(TUNNEL_TOKEN:)[^,}\]]+/\1[REDACTED]/Ig'
}

# command_slug は、見出しからファイル名に使える短い識別子を作る。
# 引数: $1にコマンド見出しを指定する。
# 戻り値: 変換した識別子を標準出力へ出す。
command_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# append_line は、障害解析レポートに1行を追記する。
# 引数: $@にレポートへ書く文字列を指定する。
# 戻り値: printfの終了コードを返す。
append_line() {
  printf '%s\n' "$*" >>"${REPORT}"
}

# have_command は、コマンドが実行可能かを確認する。
# 引数: $1に確認するコマンド名を指定する。
# 戻り値: コマンドが見つかれば0、見つからなければ非0。
have_command() {
  command -v "$1" >/dev/null 2>&1
}

# run_section は、コマンド出力をMarkdownとrawログへ同時に保存する。
# 引数: $1にMarkdown見出し、$2以降に実行するコマンドと引数を指定する。
# 戻り値: 採取継続を優先するため常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
run_section() {
  local title="$1"
  shift

  local slug raw_file tmp_file status
  slug="$(command_slug "${title}")"
  raw_file="${RAW_DIR}/${slug}.log"
  tmp_file="${RAW_DIR}/${slug}.tmp"
  status=0

  append_line
  append_line "## ${title}"
  append_line
  append_line '```bash'
  printf '%q ' "$@" >>"${REPORT}"
  append_line
  append_line '```'
  append_line
  append_line '```text'

  if have_command timeout; then
    if timeout "${COMMAND_TIMEOUT}" "$@" >"${tmp_file}" 2>&1; then
      status=0
    else
      status=$?
    fi
  else
    if "$@" >"${tmp_file}" 2>&1; then
      status=0
    else
      status=$?
    fi
  fi

  redact <"${tmp_file}" >"${raw_file}"
  cat "${raw_file}" >>"${REPORT}"
  append_line '```'
  append_line
  append_line "exit_status: ${status}"
  rm -f -- "${tmp_file}"
  return 0
}

# run_shell_section は、pipeやglobが必要な調査コマンドを保存する。
# 引数: $1にMarkdown見出し、$2にbash -lcへ渡すコマンド文字列を指定する。
# 戻り値: 採取継続を優先するため常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
run_shell_section() {
  local title="$1"
  local command_text="$2"
  run_section "${title}" bash -lc "${command_text}"
}

# write_triage_header は、Codexが最初に読むべき要約と確認順序を出力する。
# 引数: なし。
# 戻り値: レポートを初期化できれば0。
# 副作用: REPORTを初期化する。
write_triage_header() {
  cat >"${REPORT}" <<EOF
# InferLab Network Triage

- run_id: ${RUN_ID}
- generated_at: $(date --iso-8601=seconds 2>/dev/null || date)
- hostname: $(hostname 2>/dev/null || true)
- stack_name: ${STACK_NAME}
- gateway_ip: ${GATEWAY_IP}
- primary_bridge: ${PRIMARY_BRIDGE}
- primary_nic: ${PRIMARY_NIC}
- docker_nic: ${DOCKER_DEV}
- journal_lines: ${JOURNAL_LINES}
- docker_since: ${DOCKER_SINCE}
- docker_log_lines: ${DOCKER_LOG_LINES}
- command_timeout: ${COMMAND_TIMEOUT}

## Codex向け確認ポイント

- 最初に \`read-first-gateway-l2-verdict\` と \`gateway-neighbor-priority-snapshot\` を確認する。
- \`gateway-dual-nic-packet-capture\`の\`verdict\`で、gateway ARP replyが\`${DOCKER_DEV}\`へ誤配送されていないか確認する。
- \`${GATEWAY_IP} dev ${PRIMARY_BRIDGE} FAILED\` があれば、DNSではなくgateway ARP/L2到達不能として扱う。
- \`memory-pressure-and-oom\`、\`kernel-oom-current-boot\`、\`docker-resource-state\`で、TEI起動時のOOM、swap枯渇、再起動loopを確認する。
- \`journal-list-boots\`と前回bootのkernel/network logを使い、再起動で失われたruntime状態と区別する。
- \`cloudflare-container-logs\`の \`no route to host\` はDNSより下の外向き経路障害を示す。
- \`docker-resolver-errors-current-boot\`と \`docker-resolver-errors-previous-boot\`で、問い合わせ元IPと対象FQDNを対応づける。
- \`docker-network-inspect-internal\`で、障害時ログの \`client-addr\` とコンテナ名の対応を確認する。
- \`nic-driver-deep-dive\`で両NICのdriver、firmware、PCI、offload、error counterを確認する。

EOF
}

# collect_gateway_l2_priority は、再発時に最初に見るべきgateway ARP状態を採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: gatewayへ短いARP、ICMP probeを送り、REPORTとRAW_DIRへ記録する。
collect_gateway_l2_priority() {
  run_shell_section "read-first-gateway-l2-verdict" "printf 'gateway_ip=%s\nprimary_bridge=%s\nprimary_nic=%s\n\n' '${GATEWAY_IP}' '${PRIMARY_BRIDGE}' '${PRIMARY_NIC}'; printf '%s\n' '--- gateway neighbor ---'; ip neigh show '${GATEWAY_IP}' || true; printf '\n%s\n' '--- all failed neighbors ---'; ip neigh | grep -E 'FAILED|INCOMPLETE|DELAY|PROBE' || true; printf '\n%s\n' '--- default route ---'; ip route show default || true; printf '\n%s\n' '--- gateway ping ---'; ping -c 3 -W 2 '${GATEWAY_IP}' || true; printf '\n%s\n' '--- external ping ---'; ping -c 3 -W 2 1.1.1.1 || true"
  run_shell_section "gateway-neighbor-priority-snapshot" "for i in 1 2 3; do printf '\n--- sample %s %s ---\n' \"\$i\" \"\$(date --iso-8601=seconds 2>/dev/null || date)\"; ip neigh show '${GATEWAY_IP}' || true; ip -s link show '${PRIMARY_NIC}' || true; ip -s link show '${PRIMARY_BRIDGE}' || true; sleep 1; done"
  run_shell_section "gateway-arp-probe" "if command -v arping >/dev/null 2>&1; then arping -c 5 -w 5 -I '${PRIMARY_BRIDGE}' '${GATEWAY_IP}' || arping -c 5 -w 5 -I '${PRIMARY_NIC}' '${GATEWAY_IP}' || true; else printf 'arping not installed\n'; fi"
  collect_dual_nic_gateway_capture
}

# collect_dual_nic_gateway_capture は、管理NIC向けARP応答の到着先を両NIC同時captureで判定する。
# 引数: なし。
# 戻り値: 採取継続を優先するため常に0。
# 副作用: 両NICを一時的にpromiscuous modeにし、gatewayへICMP probeを送ってREPORTとRAW_DIRへ記録する。
collect_dual_nic_gateway_capture() {
  local command_text
  command_text="$(cat <<EOF
if ! command -v tcpdump >/dev/null 2>&1; then
  printf 'verdict=TCPDUMP_NOT_INSTALLED\n'
  exit 0
fi

capture_dir="\$(mktemp -d /tmp/inferlab-gateway-capture.XXXXXX)"
primary_capture="\${capture_dir}/${PRIMARY_NIC}.log"
docker_capture="\${capture_dir}/${DOCKER_DEV}.log"
probe_capture="\${capture_dir}/gateway-probe.log"
# cleanup は、両NICの一時captureを削除する。
# 引数: なし。
# 戻り値: 一時directoryを削除できれば0。
cleanup() {
  rm -f -- "\${primary_capture}" "\${docker_capture}" "\${probe_capture}"
  rmdir -- "\${capture_dir}" 2>/dev/null || true
}
trap cleanup EXIT

timeout 15 tcpdump -l -eni '${PRIMARY_NIC}' -vv 'arp or (icmp and host ${GATEWAY_IP})' >"\${primary_capture}" 2>&1 &
primary_pid=\$!
timeout 15 tcpdump -l -eni '${DOCKER_DEV}' -vv 'arp or (icmp and host ${GATEWAY_IP})' >"\${docker_capture}" 2>&1 &
docker_pid=\$!
sleep 1
ping -I '${PRIMARY_BRIDGE}' -c 5 -W 2 '${GATEWAY_IP}' >"\${probe_capture}" 2>&1 || true
wait "\${primary_pid}" || true
wait "\${docker_pid}" || true

primary_requests="\$(grep -Ec 'Request who-has ${GATEWAY_IP} tell' "\${primary_capture}" || true)"
primary_replies="\$(grep -Ec 'Reply ${GATEWAY_IP} is-at' "\${primary_capture}" || true)"
docker_requests="\$(grep -Ec 'Request who-has ${GATEWAY_IP} tell' "\${docker_capture}" || true)"
docker_replies="\$(grep -Ec 'Reply ${GATEWAY_IP} is-at' "\${docker_capture}" || true)"

printf 'primary_nic=%s\n' '${PRIMARY_NIC}'
printf 'docker_nic=%s\n' '${DOCKER_DEV}'
printf 'gateway_ip=%s\n' '${GATEWAY_IP}'
printf 'primary_requests=%s\n' "\${primary_requests}"
printf 'primary_replies=%s\n' "\${primary_replies}"
printf 'docker_requests=%s\n' "\${docker_requests}"
printf 'docker_replies=%s\n' "\${docker_replies}"

if ((primary_replies > 0 && docker_replies > 0)); then
  printf 'verdict=GATEWAY_ARP_REPLY_SEEN_ON_BOTH_NICS\n'
elif ((primary_replies > 0)); then
  printf 'verdict=GATEWAY_ARP_REPLY_SEEN_ON_PRIMARY_NIC\n'
elif ((docker_replies > 0)); then
  printf 'verdict=GATEWAY_ARP_REPLY_MISDIRECTED_TO_DOCKER_NIC\n'
elif ((primary_requests > 0)); then
  printf 'verdict=NO_GATEWAY_ARP_REPLY_ON_EITHER_NIC\n'
else
  printf 'verdict=NO_PRIMARY_GATEWAY_ARP_REQUEST_OBSERVED\n'
fi

printf '\n--- gateway probe ---\n'
cat "\${probe_capture}"
printf '\n--- ${PRIMARY_NIC} capture ---\n'
cat "\${primary_capture}"
printf '\n--- ${DOCKER_DEV} capture ---\n'
cat "\${docker_capture}"
EOF
)"
  run_shell_section "gateway-dual-nic-packet-capture" "${command_text}"
}

# collect_host_state は、ホスト側のネットワーク実体と永続設定を採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_host_state() {
  run_section "basic-host-info" date
  run_section "kernel-and-uptime" bash -lc 'uname -a; printf "\n"; uptime'
  run_shell_section "journal-list-boots" 'journalctl --list-boots --no-pager | tail -60'
  run_section "ip-addresses" ip addr
  run_section "ip-links" ip link
  run_section "host-route-and-neighbor" bash -lc 'ip route; printf "\n--- ip rule ---\n"; ip rule; printf "\n--- all route tables ---\n"; ip route show table all; printf "\n--- ip neigh ---\n"; ip neigh'
  run_shell_section "mac-address-comparison" "printf '%s ' '${PRIMARY_NIC}'; cat '/sys/class/net/${PRIMARY_NIC}/address' 2>/dev/null || true; printf '%s ' '${PRIMARY_BRIDGE}'; cat '/sys/class/net/${PRIMARY_BRIDGE}/address' 2>/dev/null || true; printf '%s ' '${DOCKER_DEV}'; cat '/sys/class/net/${DOCKER_DEV}/address' 2>/dev/null || true; printf '\n--- ${PRIMARY_NIC} link details ---\n'; ip -d link show '${PRIMARY_NIC}' || true; printf '\n--- ${PRIMARY_BRIDGE} link details ---\n'; ip -d link show '${PRIMARY_BRIDGE}' || true; printf '\n--- ${DOCKER_DEV} link details ---\n'; ip -d link show '${DOCKER_DEV}' || true"
  run_section "bridge-link" bridge link
  run_section "bridge-vlan" bridge vlan
  run_section "bridge-fdb-show" bridge fdb show
  run_shell_section "bridge-fdb-primary-path" "bridge fdb show brport '${PRIMARY_NIC}' 2>/dev/null || true; printf '\n--- gateway neighbor ---\n'; ip neigh show '${GATEWAY_IP}' || true"
  run_section "resolvectl-status" resolvectl status
  run_shell_section "resolv-conf" 'ls -l /etc/resolv.conf; printf "\n"; cat /etc/resolv.conf'
  run_section "networkctl" networkctl
  run_section "nmcli-device" nmcli device
  run_shell_section "networkmanager-connection-details" "nmcli -f connection,bridge,802-3-ethernet connection show '${HOST_CONN}' 2>&1 || true; printf '\n--- ${PRIMARY_NIC} connection candidates ---\n'; nmcli -f connection,bridge,802-3-ethernet connection show 2>&1 | sed -n '1,260p' || true"
  run_shell_section "network-config-files" 'for path in /etc/netplan/* /etc/systemd/network/* /etc/NetworkManager/system-connections/* /etc/NetworkManager/conf.d/*; do [ -e "$path" ] || continue; printf "\n--- %s ---\n" "$path"; sed -E "s/(password|psk|key|secret|token)=.*/\1=[REDACTED]/Ig" "$path"; done'
}

# collect_runtime_health は、現在の疎通、NIC、memory、conntrack状態を採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_runtime_health() {
  run_section "gateway-ping" ping -c 3 -W 2 "${GATEWAY_IP}"
  run_section "external-ip-ping" ping -c 3 -W 2 1.1.1.1
  run_section "dns-resolution" bash -lc 'getent hosts cloudflare.com; getent hosts discord.com; getent hosts region1.v2.argotunnel.com'
  run_shell_section "nic-driver-and-stats" "for nic in '${PRIMARY_NIC}' '${DOCKER_DEV}'; do printf '\n--- %s ---\n' \"\$nic\"; readlink \"/sys/class/net/\${nic}/device/driver\" || true; cat \"/sys/class/net/\${nic}/operstate\" 2>/dev/null || true; for counter in rx_errors tx_errors rx_dropped tx_dropped collisions carrier_changes; do printf '%s=' \"\$counter\"; cat \"/sys/class/net/\${nic}/statistics/\${counter}\" 2>/dev/null || true; done; ip -s link show \"\$nic\" || true; done"
  run_section "ethtool-primary-nic" ethtool "${PRIMARY_NIC}"
  run_section "ethtool-driver-primary-nic" ethtool -i "${PRIMARY_NIC}"
  run_section "ethtool-offload-primary-nic" ethtool -k "${PRIMARY_NIC}"
  run_section "ethtool-eee-primary-nic" ethtool --show-eee "${PRIMARY_NIC}"
  run_section "ethtool-pause-primary-nic" ethtool --show-pause "${PRIMARY_NIC}"
  run_section "ethtool-stats-primary-nic" ethtool -S "${PRIMARY_NIC}"
  run_section "ethtool-docker-nic" ethtool "${DOCKER_DEV}"
  run_section "ethtool-driver-docker-nic" ethtool -i "${DOCKER_DEV}"
  run_section "ethtool-stats-docker-nic" ethtool -S "${DOCKER_DEV}"
  run_shell_section "nic-driver-deep-dive" "for nic in '${PRIMARY_NIC}' '${DOCKER_DEV}'; do printf '\n--- %s driver symlink ---\n' \"\$nic\"; readlink \"/sys/class/net/\${nic}/device/driver\" || true; printf '%s\n' '--- module symlink ---'; readlink \"/sys/class/net/\${nic}/device/driver/module\" || true; printf '%s\n' '--- PCI modalias ---'; cat \"/sys/class/net/\${nic}/device/modalias\" 2>/dev/null || true; printf '%s\n' '--- device power control ---'; cat \"/sys/class/net/\${nic}/device/power/control\" 2>/dev/null || true; done; printf '\n%s\n' '--- r8168 module parameters ---'; for path in /sys/module/r8168/parameters/*; do [ -e \"\$path\" ] || continue; printf '%s=' \"\$(basename \"\$path\")\"; cat \"\$path\"; done; printf '\n%s\n' '--- PCI and loaded drivers ---'; if command -v lspci >/dev/null 2>&1; then lspci -nnk | grep -A4 -i -E 'ethernet|network|realtek|r816'; else printf 'lspci not installed\n'; fi; printf '\n%s\n' '--- loaded r816 modules ---'; lsmod | grep -E '^r8168|^r8169|realtek' || true; printf '\n%s\n' '--- modinfo r8168 ---'; modinfo r8168 2>/dev/null | sed -n '1,120p' || true; printf '\n%s\n' '--- modinfo r8169 ---'; modinfo r8169 2>/dev/null | sed -n '1,120p' || true; printf '\n%s\n' '--- recent NIC kernel messages ---'; journalctl -b -k --no-pager | grep -Ei '${PRIMARY_NIC}|${DOCKER_DEV}|r8168|r8169|realtek|NETDEV|watchdog|tx timeout|reset|link is|carrier' | tail -500 || true"
  run_shell_section "memory-pressure-and-oom" "printf '%s\n' '--- free ---'; free -h; printf '\n%s\n' '--- swap ---'; swapon --show --bytes || true; printf '\n%s\n' '--- vmstat ---'; vmstat 1 5 || true; printf '\n%s\n' '--- pressure ---'; for path in /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory; do printf '\n%s\n' \"--- \$path ---\"; cat \"\$path\" 2>/dev/null || true; done; printf '\n%s\n' '--- overcommit and swappiness ---'; sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness 2>/dev/null || true"
  run_shell_section "kernel-oom-current-boot" "journalctl -b -k --no-pager | grep -Ei 'out of memory|oom-kill|killed process|memory cgroup out of memory|page allocation failure' | tail -1200 || true"
  run_shell_section "kernel-oom-previous-boot" "journalctl -b -1 -k --no-pager | grep -Ei 'out of memory|oom-kill|killed process|memory cgroup out of memory|page allocation failure' | tail -1200 || true"
  run_shell_section "cgroup-memory-events" "find /sys/fs/cgroup -maxdepth 5 -type f \\( -name memory.events -o -name memory.events.local \\) -print 2>/dev/null | while read -r path; do if grep -Eq 'oom [1-9]|oom_kill [1-9]|max [1-9]' \"\$path\"; then printf '\n--- %s ---\n' \"\$path\"; cat \"\$path\"; fi; done"
  run_section "conntrack-count" conntrack -C
  run_section "conntrack-stats" conntrack -S
  run_section "conntrack-sysctl" sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count
  run_section "socket-summary" ss -s
  run_section "memory-and-load" bash -lc 'free -h; printf "\n"; cat /proc/loadavg'
  run_shell_section "top-processes" "printf '%s\n' '--- memory ---'; ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,comm,args --sort=-rss | head -80; printf '\n%s\n' '--- cpu ---'; ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,comm,args --sort=-%cpu | head -80"
}

# collect_services は、network、Docker、SSH、egress serviceの状態とjournalを採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_services() {
  run_section "networkmanager-status" systemctl status NetworkManager --no-pager
  run_section "systemd-networkd-status" systemctl status systemd-networkd --no-pager
  run_section "systemd-resolved-status" systemctl status systemd-resolved --no-pager
  run_section "docker-status" systemctl status docker --no-pager
  run_section "ssh-status" systemctl status ssh --no-pager
  run_section "egress-service-status" systemctl status inferlab-docker-egress-enp3s0.service --no-pager
  run_section "current-boot-network-journal" journalctl -b -n "${JOURNAL_LINES}" -u NetworkManager -u systemd-networkd -u systemd-resolved -u docker -u ssh -u inferlab-docker-egress-enp3s0.service --no-pager
  run_section "previous-boot-network-journal" journalctl -b -1 -n "${JOURNAL_LINES}" -u NetworkManager -u systemd-networkd -u systemd-resolved -u docker -u ssh -u inferlab-docker-egress-enp3s0.service --no-pager
  run_section "current-boot-kernel-network" journalctl -b -k -n "${JOURNAL_LINES}" --no-pager
  run_section "previous-boot-kernel-network" journalctl -b -1 -k -n "${JOURNAL_LINES}" --no-pager
  run_shell_section "docker-resolver-errors-current-boot" 'journalctl -b --no-pager --grep "failed to query external DNS server|no route to host|network is unreachable|Temporary failure in name resolution|i/o timeout" -n 1200'
  run_shell_section "docker-resolver-errors-previous-boot" 'journalctl -b -1 --no-pager --grep "failed to query external DNS server|no route to host|network is unreachable|Temporary failure in name resolution|i/o timeout" -n 1200'
  run_section "egress-dispatcher-journal" journalctl -t inferlab-docker-egress -b -n 500 --no-pager
}

# collect_docker_state は、Docker network、resource、重要コンテナの状態とログを採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_docker_state() {
  run_section "docker-ps" docker ps --no-trunc
  run_section "docker-ps-all" docker ps -a --no-trunc
  run_section "docker-resource-state" docker stats --no-stream --all
  run_shell_section "docker-restart-and-oom-state" 'docker ps -aq | while read -r id; do docker inspect --format "{{.Name}} status={{.State.Status}} oom_killed={{.State.OOMKilled}} exit={{.State.ExitCode}} restart_count={{.RestartCount}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}" "$id"; done | sort'
  run_section "docker-info" docker info
  run_section "docker-network-ls" docker network ls
  run_section "docker-network-inspect-internal" docker network inspect "${STACK_NAME}_internal-nw"
  run_section "docker-network-inspect-keycloak" docker network inspect "${STACK_NAME}_keycloak-nw"
  run_section "docker-network-inspect-bridge" docker network inspect bridge
  run_shell_section "docker-container-ip-map" 'docker ps --format "{{.Names}}" | sort | while read -r name; do printf "\n--- %s ---\n" "$name"; docker inspect --format "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}" "$name"; done'
  run_section "docker-compose-ps-all-profiles" docker compose --profile common --profile infra --profile inference --profile webui --profile storage --profile developer --profile automation --profile team-chat --profile team-project --profile team-wiki --profile llmops ps
  run_section "cloudflare-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-cloudflare"
  run_section "hermes-agent-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-hermes-agent"
  run_section "tei-embedding-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-tei-embedding"
  run_section "tei-reranking-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-tei-reranking"
  run_section "docling-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-docling"
  run_section "open-webui-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-open-webui"
  run_section "open-terminal-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-open-terminal"
  run_section "ollama-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-ollama"
  run_section "qdrant-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-qdrant"
}

# write_triage_footer は、採取結果の保存場所をレポート末尾に残す。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTへ末尾情報を追記する。
write_triage_footer() {
  append_line
  append_line "## 保存先"
  append_line
  append_line "- report: ${REPORT}"
  append_line "- raw_dir: ${RAW_DIR}"
}

# run_triage は、次回障害を再起動前に解析できる証拠一式を採取する。
# 引数: なし。
# 戻り値: reportを作成できれば0。個別コマンド失敗では採取を継続する。
# 副作用: OUTPUT_ROOT配下へMarkdown reportとrawログを作成する。
run_triage() {
  require_root
  initialize_output_paths
  write_triage_header
  collect_gateway_l2_priority
  collect_host_state
  collect_runtime_health
  collect_services
  collect_docker_state
  write_triage_footer
  printf 'Network triage report created: %s\n' "${REPORT}"
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
  local host_nic_mac host_bridge_mac
  host_nic_mac="$(cat "/sys/class/net/${HOST_NIC}/address" 2>/dev/null || true)"
  host_bridge_mac="$(cat "/sys/class/net/${HOST_DEV}/address" 2>/dev/null || true)"

  print_section "host bridge MAC"
  printf '%s physical MAC: %s\n' "${HOST_NIC}" "${host_nic_mac:-unknown}"
  printf '%s runtime MAC: %s\n' "${HOST_DEV}" "${host_bridge_mac:-unknown}"
  nmcli --escape no -g bridge.mac-address connection show "${HOST_CONN}" 2>/dev/null \
    | sed "s/^/${HOST_CONN} configured MAC: /" || true

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

# valid_unicast_mac は、NetworkManagerへ設定可能なunicast MACかを検証する。
# 引数: $1に検証するMACアドレスを指定する。
# 戻り値: 形式が正しくunicastなら0、それ以外は1。
valid_unicast_mac() {
  local mac="${1,,}"
  local first_octet

  [[ "${mac}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
  [[ "${mac}" != "00:00:00:00:00:00" ]] || return 1
  first_octet="${mac%%:*}"
  (( (16#${first_octet} & 1) == 0 ))
}

# run_pin_host_mac は、bridge0の永続MACを管理NICの物理MACへ固定する。
# 引数: なし。HOST_CONN、HOST_DEV、HOST_NICを使用する。
# 戻り値: NetworkManagerプロファイルを更新できれば0。
# 副作用: 変更前設定をOUTPUT_ROOTへ保存し、NetworkManagerのbridgeプロファイルを変更する。稼働中interfaceは再接続しない。
run_pin_host_mac() {
  require_root

  local host_nic_mac runtime_mac backup_file configured_mac
  if ! connection_exists "${HOST_CONN}"; then
    echo "ERROR: NetworkManager接続 ${HOST_CONN} が見つかりません。" >&2
    exit 1
  fi

  host_nic_mac="$(tr '[:upper:]' '[:lower:]' <"/sys/class/net/${HOST_NIC}/address")"
  if ! valid_unicast_mac "${host_nic_mac}"; then
    echo "ERROR: ${HOST_NIC}から有効なunicast MACを取得できません: ${host_nic_mac}" >&2
    exit 1
  fi

  mkdir -p "${OUTPUT_ROOT}"
  backup_file="${OUTPUT_ROOT%/}/${HOST_CONN}-before-mac-pin-${RUN_ID}.log"
  nmcli connection show "${HOST_CONN}" >"${backup_file}"

  runtime_mac="$(cat "/sys/class/net/${HOST_DEV}/address" 2>/dev/null || true)"
  print_section "before host bridge MAC pin"
  printf '%s physical MAC: %s\n' "${HOST_NIC}" "${host_nic_mac}"
  printf '%s runtime MAC: %s\n' "${HOST_DEV}" "${runtime_mac:-unknown}"
  printf 'backup: %s\n' "${backup_file}"

  nmcli connection modify "${HOST_CONN}" bridge.mac-address "${host_nic_mac}"
  configured_mac="$(nmcli --escape no -g bridge.mac-address connection show "${HOST_CONN}")"

  print_section "persistent host bridge MAC"
  printf '%s configured MAC: %s\n' "${HOST_CONN}" "${configured_mac:-unset}"
  printf '%s runtime MAC: %s\n' "${HOST_DEV}" "${runtime_mac:-unknown}"
  printf '設定は永続化済みです。ローカルコンソールを確保して再起動し、./nwchk.sh statusで反映を確認してください。\n'
}

# run_unpin_host_mac は、bridge0の永続MAC固定を解除する。
# 引数: なし。HOST_CONNを使用する。
# 戻り値: NetworkManagerプロファイルを更新できれば0。
# 副作用: NetworkManagerのbridge MAC設定を既定値へ戻す。稼働中interfaceは再接続しない。
run_unpin_host_mac() {
  require_root

  if ! connection_exists "${HOST_CONN}"; then
    echo "ERROR: NetworkManager接続 ${HOST_CONN} が見つかりません。" >&2
    exit 1
  fi

  nmcli connection modify "${HOST_CONN}" bridge.mac-address ""

  print_section "persistent host bridge MAC"
  printf '%s configured MAC: ' "${HOST_CONN}"
  nmcli --escape no -g bridge.mac-address connection show "${HOST_CONN}" || true
  printf 'MAC固定を解除しました。ローカルコンソールを確保して再起動し、./nwchk.sh statusで反映を確認してください。\n'
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
# 副作用: systemd unitとNetworkManager dispatcherを配置し、自動再適用を有効化する。
run_install_service() {
  require_root

  if [[ ! -f "${EGRESS_DISPATCHER}" ]]; then
    echo "ERROR: ${EGRESS_DISPATCHER} が見つかりません。" >&2
    exit 1
  fi

  install -m 0755 "${EGRESS_SCRIPT}" /usr/local/sbin/inferlab-docker-egress-enp3s0.sh
  install -m 0644 "${EGRESS_SERVICE}" /etc/systemd/system/inferlab-docker-egress-enp3s0.service
  install -m 0755 "${EGRESS_DISPATCHER}" "${EGRESS_DISPATCHER_TARGET}"
  systemctl daemon-reload
  systemctl enable inferlab-docker-egress-enp3s0.service
  systemctl restart inferlab-docker-egress-enp3s0.service
  systemctl status inferlab-docker-egress-enp3s0.service --no-pager
  ls -l "${EGRESS_DISPATCHER_TARGET}"
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
    timeout 25 tcpdump -l -nn -i "${docker_br}" '(arp or host 1.1.1.1 or port 53)' >"${bridge_capture}" 2>&1 &
    bridge_pid=$!
    timeout 25 tcpdump -l -nn -i "${DOCKER_DEV}" '(arp or host 1.1.1.1 or port 53)' >"${egress_capture}" 2>&1 &
    egress_pid=$!
    sleep 1
  else
    bridge_pid=""
    egress_pid=""
    echo "WARN: tcpdumpがないためpacket captureを省略します。" >&2
  fi

  print_section "docker test"
  docker run --rm --pull never --network "${DOCKER_NETWORK}" curlimages/curl:latest \
    sh -c 'ip -4 addr; ip route; ip neigh; cat /etc/resolv.conf; curl -4 --max-time 5 https://1.1.1.1/cdn-cgi/trace | head || true; ip neigh; getent ahostsv4 example.com || true; ip neigh' || true

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

# run_diagnose_logged は、Docker egress診断を実行して指定先へ秘匿化済みログを保存する。
# 引数: なし。OUTPUT_ROOTとRUN_IDを使用する。
# 戻り値: 診断処理の終了コードを返す。
# 副作用: OUTPUT_ROOT配下にEGRESS_DIAGNOSE.logを作成する。
run_diagnose_logged() {
  require_root
  initialize_output_paths

  local tmp_file="${OUT_DIR}/EGRESS_DIAGNOSE.tmp"
  local log_file="${OUT_DIR}/EGRESS_DIAGNOSE.log"
  local status=0

  if run_diagnose 2>&1 | tee "${tmp_file}"; then
    status=0
  else
    status=$?
  fi

  redact <"${tmp_file}" >"${log_file}"
  rm -f -- "${tmp_file}"
  printf 'Egress diagnostic log created: %s\n' "${log_file}"
  return "${status}"
}

# run_rollback は、Docker egress分離のランタイム設定を削除する。
# 引数: なし。
# 戻り値: 削除処理を完了すれば0。
# 副作用: dispatcher、systemd service、ip rule、table 103、iptables、UFWの追加ルール、docker-enp3s0接続を停止する。
run_rollback() {
  require_root

  rm -f -- "${EGRESS_DISPATCHER_TARGET}"
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

# parse_args は、サブコマンドと診断ログ保存先を解釈する。
# 引数: $@にサブコマンド、--output-dirまたは-oを指定する。
# 戻り値: 引数が正しければ0。不正な引数では終了コード2で終了する。
# 副作用: COMMANDとOUTPUT_ROOTを更新する。
parse_args() {
  while (($# > 0)); do
    case "$1" in
      -o|--output-dir)
        if (($# < 2)) || [[ -z "$2" ]]; then
          echo "ERROR: $1 には保存先directoryが必要です。" >&2
          exit 2
        fi
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --output-dir=*)
        OUTPUT_ROOT="${1#*=}"
        if [[ -z "${OUTPUT_ROOT}" ]]; then
          echo "ERROR: --output-dirには保存先directoryが必要です。" >&2
          exit 2
        fi
        shift
        ;;
      -h|--help|help)
        COMMAND="help"
        shift
        ;;
      -*)
        echo "ERROR: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
      *)
        if [[ -n "${COMMAND}" ]]; then
          echo "ERROR: subcommandは1つだけ指定できます: $1" >&2
          usage >&2
          exit 2
        fi
        COMMAND="$1"
        shift
        ;;
    esac
  done

  COMMAND="${COMMAND:-triage}"
}

# main は、引数を解釈して対応するネットワーク操作または障害採取を実行する。
# 引数: $@にサブコマンドとoptionを受け取る。
# 戻り値: サブコマンドの終了コードを返す。不明なサブコマンドでは2で終了する。
main() {
  parse_args "$@"
  case "${COMMAND}" in
    triage|collect)
      run_triage
      ;;
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
      run_diagnose_logged
      ;;
    pin-host-mac)
      run_pin_host_mac
      ;;
    unpin-host-mac)
      run_unpin_host_mac
      ;;
    install-service)
      run_install_service
      ;;
    rollback)
      run_rollback
      ;;
    help)
      usage
      ;;
    *)
      usage >&2
      echo "ERROR: unknown command: ${COMMAND}" >&2
      exit 2
      ;;
  esac
}

main "$@"
