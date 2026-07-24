#!/usr/bin/env bash

set -uo pipefail

# 障害時ログの採取範囲と保存先を、環境変数で上書きできるようにする。
readonly STACK_NAME="${STACK_NAME:-inferlab}"
readonly JOURNAL_LINES="${JOURNAL_LINES:-4000}"
readonly DOCKER_LOG_LINES="${DOCKER_LOG_LINES:-1200}"
readonly DOCKER_SINCE="${DOCKER_SINCE:-6h}"
readonly COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-45s}"
readonly OUTPUT_ROOT="${OUTPUT_ROOT:-triage-logs}"
readonly RUN_ID="$(date '+%Y%m%d-%H%M%S-%Z')"
readonly OUT_DIR="${OUTPUT_ROOT}/${RUN_ID}"
readonly RAW_DIR="${OUT_DIR}/raw"
readonly REPORT="${OUT_DIR}/NETWORK_TRIAGE.md"

mkdir -p "${RAW_DIR}"

# redact は、Codex へ渡すログに認証情報が混ざるリスクを下げる。
# 引数: なし。標準入力からログ本文を受け取る。
# 戻り値: 常に sed の終了コードを返す。
redact() {
  sed -E \
    -e 's/((TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|PRIVATE[_-]?KEY|ACCESS[_-]?KEY|CLIENT[_-]?SECRET|AUTHORIZATION)[A-Za-z0-9_ -]*[:=][[:space:]]*)[^[:space:]"'"'"']+/\1[REDACTED]/Ig' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/Ig' \
    -e 's/(Basic )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/Ig' \
    -e 's/(TUNNEL_TOKEN:)[^,}\]]+/\1[REDACTED]/Ig'
}

# command_slug は、見出しからファイル名に使える短い識別子を作る。
# 引数:
#   $1: コマンド見出し。
# 戻り値: 変換した識別子を標準出力へ出す。
command_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# append_line は、レポートに1行を追記する。
# 引数:
#   $@: レポートへ書く文字列。
# 戻り値: printf の終了コードを返す。
append_line() {
  printf '%s\n' "$*" >>"${REPORT}"
}

# have_command は、コマンドが実行可能かを確認する。
# 引数:
#   $1: 確認するコマンド名。
# 戻り値: コマンドが見つかれば0、見つからなければ非0。
have_command() {
  command -v "$1" >/dev/null 2>&1
}

# run_section は、コマンド出力をMarkdownとrawログへ同時に保存する。
# 引数:
#   $1: Markdown見出し。
#   $2...: 実行するコマンドと引数。
# 戻り値: 採取継続を優先するため常に0を返す。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
run_section() {
  local title="$1"
  shift

  local slug
  slug="$(command_slug "${title}")"
  local raw_file="${RAW_DIR}/${slug}.log"
  local tmp_file="${RAW_DIR}/${slug}.tmp"
  local status=0

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
    timeout "${COMMAND_TIMEOUT}" "$@" >"${tmp_file}" 2>&1
    status=$?
  else
    "$@" >"${tmp_file}" 2>&1
    status=$?
  fi

  redact <"${tmp_file}" >"${raw_file}"
  cat "${raw_file}" >>"${REPORT}"
  append_line '```'
  append_line
  append_line "exit_status: ${status}"
  rm -f "${tmp_file}"
  return 0
}

# run_shell_section は、パイプやglobが必要な調査コマンドを保存する。
# 引数:
#   $1: Markdown見出し。
#   $2: bash -lc に渡すコマンド文字列。
# 戻り値: 採取継続を優先するため常に0を返す。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
run_shell_section() {
  local title="$1"
  local command_text="$2"

  run_section "${title}" bash -lc "${command_text}"
}

# write_header は、Codexが最初に読むべき要約と使い方を出力する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTを初期化する。
write_header() {
  cat >"${REPORT}" <<EOF
# InferLab Network Triage

- run_id: ${RUN_ID}
- generated_at: $(date --iso-8601=seconds 2>/dev/null || date)
- hostname: $(hostname 2>/dev/null || true)
- stack_name: ${STACK_NAME}
- journal_lines: ${JOURNAL_LINES}
- docker_since: ${DOCKER_SINCE}
- docker_log_lines: ${DOCKER_LOG_LINES}
- command_timeout: ${COMMAND_TIMEOUT}

## Codex向け確認ポイント

- 前回bootのログがある場合は、まず \`journal-list-boots\` と \`docker-resolver-errors-previous-boot\` を確認する。
- \`cloudflare-container-logs\` の \`no route to host\` はDNSより下の外向き経路障害を示す。
- \`docker-resolver-errors-current-boot\` と \`docker-resolver-errors-previous-boot\` で、問い合わせ元IPと対象FQDNを対応づける。
- \`docker-network-inspect-internal\` で、障害時ログの \`client-addr\` とコンテナ名の対応を確認する。
- \`host-route-and-neighbor\` で default route と gateway ARP 状態を確認する。

EOF
}

# collect_host_state は、ホスト側のネットワーク実体を採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_host_state() {
  run_section "basic-host-info" date
  run_section "kernel-and-uptime" bash -lc 'uname -a; printf "\n"; uptime'
  run_shell_section "journal-list-boots" 'journalctl --list-boots --no-pager | tail -60'
  run_section "ip-addresses" ip addr
  run_section "ip-links" ip link
  run_section "host-route-and-neighbor" bash -lc 'ip route; printf "\n--- ip rule ---\n"; ip rule; printf "\n--- ip neigh ---\n"; ip neigh'
  run_section "bridge-link" bridge link
  run_section "bridge-vlan" bridge vlan
  run_section "bridge-fdb-show" bridge fdb show
  run_section "resolvectl-status" resolvectl status
  run_shell_section "resolv-conf" 'ls -l /etc/resolv.conf; printf "\n"; cat /etc/resolv.conf'
  run_section "networkctl" networkctl
  run_section "nmcli-device" nmcli device
  run_shell_section "network-config-files" 'for path in /etc/netplan/* /etc/systemd/network/* /etc/NetworkManager/system-connections/* /etc/NetworkManager/conf.d/*; do [ -e "$path" ] || continue; printf "\n--- %s ---\n" "$path"; sed -E "s/(password|psk|key|secret|token)=.*/\1=[REDACTED]/Ig" "$path"; done'
}

# collect_runtime_health は、現在復旧後の疎通とリソース状態を採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_runtime_health() {
  run_section "gateway-ping" ping -c 3 -W 2 192.168.1.1
  run_section "external-ip-ping" ping -c 3 -W 2 1.1.1.1
  run_section "dns-resolution" bash -lc 'getent hosts cloudflare.com; getent hosts discord.com; getent hosts region1.v2.argotunnel.com'
  run_shell_section "nic-driver-and-stats" 'readlink /sys/class/net/enp2s0/device/driver; printf "\n--- operstate ---\n"; cat /sys/class/net/enp2s0/operstate; printf "\n--- statistics ---\n"; for f in rx_errors tx_errors rx_dropped tx_dropped collisions carrier_changes; do printf "%s=" "$f"; cat "/sys/class/net/enp2s0/statistics/$f" 2>/dev/null || true; done'
  run_section "ethtool-enp2s0" ethtool enp2s0
  run_section "ethtool-stats-enp2s0" ethtool -S enp2s0
  run_section "conntrack-count" conntrack -C
  run_section "conntrack-stats" conntrack -S
  run_section "conntrack-sysctl" sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count
  run_section "socket-summary" ss -s
  run_section "memory-and-load" bash -lc 'free -h; printf "\n"; cat /proc/loadavg'
}

# collect_services は、NetworkManagerやDockerなどのサービスログを採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_services() {
  run_section "networkmanager-status" systemctl status NetworkManager --no-pager
  run_section "systemd-networkd-status" systemctl status systemd-networkd --no-pager
  run_section "systemd-resolved-status" systemctl status systemd-resolved --no-pager
  run_section "docker-status" systemctl status docker --no-pager
  run_section "ssh-status" systemctl status ssh --no-pager
  run_section "current-boot-network-journal" journalctl -b -n "${JOURNAL_LINES}" -u NetworkManager -u systemd-networkd -u systemd-resolved -u docker -u ssh --no-pager
  run_section "previous-boot-network-journal" journalctl -b -1 -n "${JOURNAL_LINES}" -u NetworkManager -u systemd-networkd -u systemd-resolved -u docker -u ssh --no-pager
  run_section "current-boot-kernel-network" journalctl -b -k -n "${JOURNAL_LINES}" --no-pager
  run_section "previous-boot-kernel-network" journalctl -b -1 -k -n "${JOURNAL_LINES}" --no-pager
  run_shell_section "docker-resolver-errors-current-boot" 'journalctl -b --no-pager --grep "failed to query external DNS server|no route to host|network is unreachable|Temporary failure in name resolution|i/o timeout" -n 1200'
  run_shell_section "docker-resolver-errors-previous-boot" 'journalctl -b -1 --no-pager --grep "failed to query external DNS server|no route to host|network is unreachable|Temporary failure in name resolution|i/o timeout" -n 1200'
}

# collect_docker_state は、Dockerのネットワークと重要コンテナのログを採取する。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTとRAW_DIR配下へログを追記・作成する。
collect_docker_state() {
  run_section "docker-ps" docker ps --no-trunc
  run_section "docker-network-ls" docker network ls
  run_section "docker-network-inspect-internal" docker network inspect "${STACK_NAME}_internal-nw"
  run_section "docker-network-inspect-bridge" docker network inspect bridge
  run_shell_section "docker-container-ip-map" 'docker ps --format "{{.Names}}" | sort | while read -r name; do printf "\n--- %s ---\n" "$name"; docker inspect --format "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}" "$name"; done'
  run_section "docker-compose-ps-all-profiles" docker compose --profile common --profile infra --profile inference --profile webui --profile storage --profile developer --profile automation --profile team-chat --profile team-project --profile team-wiki --profile llmops ps
  run_section "cloudflare-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-cloudflare"
  run_section "hermes-agent-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-hermes-agent"
  run_section "docling-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-docling"
  run_section "open-webui-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-open-webui"
  run_section "ollama-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-ollama"
  run_section "qdrant-container-logs" docker logs --since "${DOCKER_SINCE}" --tail "${DOCKER_LOG_LINES}" "${STACK_NAME}-qdrant"
}

# write_footer は、採取結果の保存場所と次の読み方を最後に残す。
# 引数: なし。
# 戻り値: 常に0。
# 副作用: REPORTへ末尾情報を追記する。
write_footer() {
  append_line
  append_line "## 保存先"
  append_line
  append_line "- report: ${REPORT}"
  append_line "- raw_dir: ${RAW_DIR}"
}

write_header
collect_host_state
collect_runtime_health
collect_services
collect_docker_state
write_footer

printf 'Network triage report created: %s\n' "${REPORT}"
