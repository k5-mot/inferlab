#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly E2E_ROOT="${REPO_ROOT}/tests/e2e"
readonly COMPOSE_PLAYWRIGHT_FILE="${E2E_ROOT}/docker-compose.playwright.yml"

cd "${REPO_ROOT}"

# 使い方を表示する。
# 引数:
#   なし。
# 戻り値:
#   常に0を返す。
# 副作用:
#   利用可能なsmoke caseを標準出力へ表示する。
print_usage() {
  sed -n '1,120p' "${E2E_ROOT}/README.md"
}

# 指定commandがPATHから実行できることを確認する。
# 引数:
#   $1: 確認するcommand名。
# 戻り値:
#   commandが見つかる場合は0、見つからない場合は非0を返す。
# 副作用:
#   commandが見つからない場合はエラー内容を標準エラーへ表示する。
require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "required command not found: ${command_name}" >&2
    return 1
  fi
}

# Docker Compose pluginが利用できることを確認する。
# 引数:
#   なし。
# 戻り値:
#   Docker Compose pluginが利用できる場合は0、できない場合は非0を返す。
# 副作用:
#   Docker daemonへversion確認を要求する。
require_docker_compose() {
  require_command docker
  docker compose version >/dev/null
}

# Playwright smoke用のCompose commandを実行する。
# 引数:
#   $@: docker composeへ渡すoptionとsubcommand。
# 戻り値:
#   docker composeの終了codeをそのまま返す。
# 副作用:
#   通常のCompose構成にE2E用overrideを重ねてDocker daemonへ要求を送る。
compose_for_playwright() {
  docker compose \
    -f "${REPO_ROOT}/docker-compose.yml" \
    -f "${COMPOSE_PLAYWRIGHT_FILE}" \
    "$@"
}

# host側の未使用TCP portを1つ取得する。
# 引数:
#   なし。
# 戻り値:
#   未使用portを取得できた場合は0、取得できない場合は非0を返す。
# 副作用:
#   Pythonで一時的にTCP socketをbindする。
allocate_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

# Playwrightのnpm依存とChromium browserを専用cacheへ準備する。
# 引数:
#   なし。
# 戻り値:
#   Playwrightを実行できる状態にできた場合は0、失敗した場合は非0を返す。
# 副作用:
#   repository外のcache directoryへnpm packageとbrowser binaryを保存する。
prepare_playwright() {
  require_command node
  require_command npm

  local cache_base
  cache_base="${PLAYWRIGHT_SMOKE_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}/inferlab-playwright-smoke}}"
  readonly PLAYWRIGHT_NODE_DIR="${cache_base}/node"
  export PLAYWRIGHT_BROWSERS_PATH="${cache_base}/browsers"
  export NODE_PATH="${PLAYWRIGHT_NODE_DIR}/node_modules"

  mkdir -p "${PLAYWRIGHT_NODE_DIR}" "${PLAYWRIGHT_BROWSERS_PATH}"

  if [[ ! -f "${PLAYWRIGHT_NODE_DIR}/package.json" ]]; then
    (
      cd "${PLAYWRIGHT_NODE_DIR}"
      npm init -y >/dev/null
    )
  fi

  if [[ ! -d "${PLAYWRIGHT_NODE_DIR}/node_modules/playwright" ]]; then
    (
      cd "${PLAYWRIGHT_NODE_DIR}"
      npm install --no-audit --no-fund "playwright@${PLAYWRIGHT_VERSION:-1.62.1}"
    )
  fi

  (
    cd "${PLAYWRIGHT_NODE_DIR}"
    npm exec -- playwright install chromium
  )
}

# E2E用Keycloak HTTPS証明書を一時directoryへ生成する。
# 引数:
#   なし。
# 戻り値:
#   証明書と秘密鍵を生成できた場合は0、失敗した場合は非0を返す。
# 副作用:
#   `PLAYWRIGHT_KEYCLOAK_CERT_DIR`をexportし、一時directoryへ自己署名証明書を作成する。
generate_playwright_keycloak_cert() {
  require_command openssl

  export PLAYWRIGHT_KEYCLOAK_CERT_DIR="${PLAYWRIGHT_KEYCLOAK_CERT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/inferlab-keycloak-cert.XXXXXXXX")}"

  openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 1 \
    -nodes \
    -keyout "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}/keycloak.key" \
    -out "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}/keycloak.crt" \
    -subj "/CN=host.docker.internal" \
    -addext "subjectAltName=DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

  chmod 600 "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}/keycloak.key"
  chmod 644 "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}/keycloak.crt"
}

# compose projectを終了してvolumeとnetworkを削除する。
# 引数:
#   $@: docker composeへ渡すprofile option群。
# 戻り値:
#   cleanupに成功した場合は0、失敗した場合も呼び出し元を止めない。
# 副作用:
#   E2E用compose projectのcontainer、volume、networkを削除する。
cleanup_compose_project() {
  local compose_profiles=("$@")

  compose_for_playwright "${compose_profiles[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}

# BookStack E2E用の一時資源を削除する。
# 引数:
#   なし。
# 戻り値:
#   cleanupに成功した場合は0、失敗した場合も呼び出し元を止めない。
# 副作用:
#   E2E用compose projectと一時証明書directoryを削除する。
cleanup_bookstack_smoke() {
  cleanup_compose_project --profile keycloak --profile bookstack

  if [[ -n "${PLAYWRIGHT_KEYCLOAK_CERT_DIR:-}" && -d "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}" ]]; then
    rm -rf -- "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}"
  fi
}

# BookStack E2Eに必要なprofileだけを起動する。
# 引数:
#   なし。
# 戻り値:
#   対象serviceが起動してhealthyになった場合は0、失敗した場合は非0を返す。
# 副作用:
#   Keycloak、Keycloak HTTPS、BookStack、関連DBを含む一時compose projectを起動する。
start_bookstack_stack() {
  export PUBLIC_HOST="${PUBLIC_HOST:-host.docker.internal}"
  export STACK_NAME="${STACK_NAME:-inferlab-e2e-bookstack-$(date +%Y%m%d%H%M%S)}"
  export KEYCLOAK_HTTP_HOST_PORT="${KEYCLOAK_HTTP_HOST_PORT:-$(allocate_port)}"
  export KEYCLOAK_HTTPS_HOST_PORT="${KEYCLOAK_HTTPS_HOST_PORT:-$(allocate_port)}"
  export BOOKSTACK_HOST_PORT="${BOOKSTACK_HOST_PORT:-$(allocate_port)}"
  export BOOKSTACK_PUBLIC_URL="${BOOKSTACK_PUBLIC_URL:-http://${PUBLIC_HOST}:${BOOKSTACK_HOST_PORT}}"
  export KEYCLOAK_REALM_ADMIN_PASSWORD="${KEYCLOAK_REALM_ADMIN_PASSWORD:-admin}"
  export BOOKSTACK_SMOKE_BASE_URL="${BOOKSTACK_SMOKE_BASE_URL:-${BOOKSTACK_PUBLIC_URL}}"
  export BOOKSTACK_SMOKE_READY_URL="${BOOKSTACK_SMOKE_READY_URL:-http://127.0.0.1:${BOOKSTACK_HOST_PORT}}"
  export BOOKSTACK_SMOKE_USERNAME="${BOOKSTACK_SMOKE_USERNAME:-admin}"
  export BOOKSTACK_SMOKE_PASSWORD="${BOOKSTACK_SMOKE_PASSWORD:-${KEYCLOAK_REALM_ADMIN_PASSWORD}}"
  export PLAYWRIGHT_HOST_RESOLVER_RULES="${PLAYWRIGHT_HOST_RESOLVER_RULES:-MAP host.docker.internal 127.0.0.1}"

  local compose_profiles=(--profile keycloak --profile bookstack)
  generate_playwright_keycloak_cert
  trap 'cleanup_bookstack_smoke' EXIT

  compose_for_playwright "${compose_profiles[@]}" up -d --wait \
    keycloak \
    keycloak-https \
    bookstack
}

# BookStackの認証と新規Book作成をPlaywrightで検証する。
# 引数:
#   なし。
# 戻り値:
#   認証とBook作成が成功した場合は0、失敗した場合は非0を返す。
# 副作用:
#   BookStack上にsmoke検証用Bookを1件作成する。
run_bookstack_smoke() {
  require_docker_compose
  require_command python3
  prepare_playwright
  start_bookstack_stack

  node "${E2E_ROOT}/playwright-smoke.cjs" bookstack
}

case "${1:-bookstack}" in
  bookstack)
    run_bookstack_smoke
    ;;
  -h | --help | help)
    print_usage
    ;;
  *)
    echo "unknown smoke case: ${1}" >&2
    print_usage >&2
    exit 2
    ;;
esac
