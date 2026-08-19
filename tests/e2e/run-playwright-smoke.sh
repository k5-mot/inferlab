#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly E2E_ROOT="${REPO_ROOT}/tests/e2e"
readonly COMPOSE_PLAYWRIGHT_FILE="${E2E_ROOT}/docker-compose.playwright.yml"
readonly TEST_MANUAL="${REPO_ROOT}/docs/manual/TEST.md"
readonly -a SMOKE_CASES=(
  nextcloud
  bookstack
  kaneo
  zulip
  open-webui
  grafana
  langfuse
)

ACTIVE_SMOKE_CASE=""
ACTIVE_PROFILES=()
ACTIVE_SERVICES=()

cd "${REPO_ROOT}"

# 使い方を表示する。
# 引数:
#   なし。
# 戻り値:
#   常に0を返す。
# 副作用:
#   利用可能なsmoke caseを標準出力へ表示する。
print_usage() {
  sed -n '/^## Level 3: Playwright E2E検証$/,/^## GitHub Actionsでの実行範囲$/{
    /^## GitHub Actionsでの実行範囲$/q
    p
  }' "${TEST_MANUAL}"
}

# Playwright smokeの対象caseを表示する。
# 引数:
#   なし。
# 戻り値:
#   常に0を返す。
# 副作用:
#   対象caseを1行ずつ標準出力へ表示する。
print_cases() {
  printf '%s\n' "${SMOKE_CASES[@]}"
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
  cache_base="${PLAYWRIGHT_SMOKE_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}/playwright-smoke}}"
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

  export PLAYWRIGHT_KEYCLOAK_CERT_DIR="${PLAYWRIGHT_KEYCLOAK_CERT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/keycloak-cert.XXXXXXXX")}"

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

# Keycloak realmのdiscovery endpointが利用可能になるまで待機する。
# 引数:
#   なし。
# 戻り値:
#   endpointがHTTP 200を返した場合は0、timeoutした場合は非0を返す。
# 副作用:
#   Keycloakのhost公開portへ2秒間隔でHTTP requestを送る。
wait_for_keycloak_realm() {
  local discovery_url="http://127.0.0.1:30001/realms/prod/.well-known/openid-configuration"
  local timeout_seconds="${PLAYWRIGHT_KEYCLOAK_READY_TIMEOUT:-180}"

  python3 - "${discovery_url}" "${timeout_seconds}" <<'PY'
import sys
import time
import urllib.error
import urllib.request


def wait_for_url(url: str, timeout_seconds: int) -> None:
    """URLがHTTP 200を返すまで待機する。

    Args:
        url: 到達確認するdiscovery endpoint。
        timeout_seconds: 最大待機秒数。

    Returns:
        None。

    Raises:
        RuntimeError: 制限時間内にHTTP 200を確認できなかった場合。
    """
    deadline = time.monotonic() + timeout_seconds
    last_error = "応答なし"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                if response.status == 200:
                    return
                last_error = f"HTTP {response.status}"
        except (OSError, urllib.error.URLError) as error:
            last_error = str(error)
        time.sleep(2)
    raise RuntimeError(f"Keycloak realmの準備待ちがtimeoutしました: {last_error}")


wait_for_url(sys.argv[1], int(sys.argv[2]))
PY
}

# E2E用の一時資源を削除する。
# 引数:
#   なし。
# 戻り値:
#   cleanupに成功した場合は0、失敗した場合も呼び出し元を止めない。
# 副作用:
#   E2E用compose projectと一時証明書directoryを削除する。
cleanup_smoke() {
  if ((${#ACTIVE_PROFILES[@]} > 0)); then
    compose_for_playwright "${ACTIVE_PROFILES[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi

  if [[ -n "${PLAYWRIGHT_KEYCLOAK_CERT_DIR:-}" && -d "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}" ]]; then
    rm -rf -- "${PLAYWRIGHT_KEYCLOAK_CERT_DIR}"
  fi
}

# 全caseで共有するKeycloakとbrowser設定を準備する。
# 引数:
#   $1: 実行するsmoke case名。
# 戻り値:
#   設定に成功した場合は0、未知のcaseの場合は非0を返す。
# 副作用:
#   E2E用環境変数、cleanup用profile、起動対象serviceを設定する。
configure_smoke_case() {
  local smoke_case="$1"

  export PUBLIC_HOST="${PUBLIC_HOST:-host.docker.internal}"
  export STACK_NAME="${STACK_NAME:-e2e-${smoke_case}-$(date +%Y%m%d%H%M%S)}"
  export KEYCLOAK_REALM_ADMIN_PASSWORD="${KEYCLOAK_REALM_ADMIN_PASSWORD:-admin}"
  export PLAYWRIGHT_SMOKE_CASE="${smoke_case}"
  export PLAYWRIGHT_SMOKE_USERNAME="${PLAYWRIGHT_SMOKE_USERNAME:-admin}"
  export PLAYWRIGHT_SMOKE_PASSWORD="${PLAYWRIGHT_SMOKE_PASSWORD:-${KEYCLOAK_REALM_ADMIN_PASSWORD}}"
  export PLAYWRIGHT_HOST_RESOLVER_RULES="${PLAYWRIGHT_HOST_RESOLVER_RULES:-MAP host.docker.internal 127.0.0.1}"

  ACTIVE_SMOKE_CASE="${smoke_case}"
  ACTIVE_PROFILES=(--profile keycloak)
  ACTIVE_SERVICES=(keycloak)

  case "${smoke_case}" in
    nextcloud)
      export PLAYWRIGHT_SMOKE_BASE_URL="http://${PUBLIC_HOST}:33000"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:33000"
      ACTIVE_PROFILES+=(--profile nextcloud)
      ACTIVE_SERVICES+=(nextcloud)
      ;;
    bookstack)
      export PLAYWRIGHT_SMOKE_BASE_URL="http://${PUBLIC_HOST}:33500"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:33500"
      ACTIVE_PROFILES+=(--profile bookstack)
      ACTIVE_SERVICES+=(keycloak-https bookstack)
      ;;
    kaneo)
      export PLAYWRIGHT_SMOKE_BASE_URL="http://${PUBLIC_HOST}:33300"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:33300"
      ACTIVE_PROFILES+=(--profile kaneo)
      ACTIVE_SERVICES+=(kaneo)
      ;;
    zulip)
      export PLAYWRIGHT_SMOKE_BASE_URL="https://${PUBLIC_HOST}:33400"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:33402"
      ACTIVE_PROFILES+=(--profile zulip)
      ACTIVE_SERVICES+=(keycloak-https zulip)
      ;;
    open-webui)
      export PLAYWRIGHT_SMOKE_BASE_URL="http://${PUBLIC_HOST}:32000"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:32000"
      ACTIVE_PROFILES+=(--profile owui)
      ACTIVE_SERVICES+=(open-webui)
      ;;
    grafana)
      export PLAYWRIGHT_SMOKE_BASE_URL="http://${PUBLIC_HOST}:35000"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:35000"
      ACTIVE_PROFILES+=(--profile o11y)
      ACTIVE_SERVICES+=(grafana)
      ;;
    langfuse)
      export PLAYWRIGHT_LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-pk-lf-langfuse-project-public-key}"
      export PLAYWRIGHT_LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-sk-lf-langfuse-project-secret-key}"
      export PLAYWRIGHT_SMOKE_BASE_URL="http://${PUBLIC_HOST}:35100"
      export PLAYWRIGHT_SMOKE_READY_URL="http://127.0.0.1:35100"
      ACTIVE_PROFILES+=(--profile langfuse)
      ACTIVE_SERVICES+=(langfuse-web)
      ;;
    *)
      echo "unknown smoke case: ${smoke_case}" >&2
      return 2
      ;;
  esac
}

# 対象caseに必要なprofileとserviceだけを起動する。
# 引数:
#   なし。
# 戻り値:
#   対象serviceがhealthyになった場合は0、失敗した場合は非0を返す。
# 副作用:
#   E2E用の一時Compose projectを起動する。
start_smoke_stack() {
  generate_playwright_keycloak_cert
  trap cleanup_smoke EXIT

  # service名を明示すれば、そのserviceのprofileと依存だけが起動する。
  # `--profile`は同じprofileの全serviceを起動するため、ここでは渡さない。
  compose_for_playwright up -d --wait \
    --wait-timeout "${PLAYWRIGHT_COMPOSE_WAIT_TIMEOUT:-600}" \
    "${ACTIVE_SERVICES[@]}"

  wait_for_keycloak_realm

}

# Playwright失敗時に対象serviceの調査用logを表示する。
# 引数:
#   なし。
# 戻り値:
#   log取得に成功した場合は0、失敗した場合は非0を返す。
# 副作用:
#   起動対象serviceの直近logを標準エラーへ表示する。
print_smoke_logs() {
  compose_for_playwright logs --no-color --tail 200 "${ACTIVE_SERVICES[@]}" >&2
}

# 指定したサービスの認証と基本操作をPlaywrightで検証する。
# 引数:
#   $1: 実行するsmoke case名。
# 戻り値:
#   認証と基本操作が成功した場合は0、失敗した場合は非0を返す。
# 副作用:
#   対象service上にsmoke検証用dataを作成し、終了時に一時Compose projectを削除する。
run_smoke() {
  local smoke_case="$1"

  require_docker_compose
  require_command python3
  prepare_playwright
  configure_smoke_case "${smoke_case}"
  start_smoke_stack

  if ! node "${E2E_ROOT}/playwright-smoke.cjs" "${smoke_case}"; then
    print_smoke_logs || true
    return 1
  fi
}

# すべてのPlaywright smoke caseを1件ずつ独立実行する。
# 引数:
#   なし。
# 戻り値:
#   全caseが成功した場合は0、いずれかが失敗した場合は非0を返す。
# 副作用:
#   caseごとに子processを起動し、一時Compose projectを順番に作成・削除する。
run_all_smokes() {
  local smoke_case

  for smoke_case in "${SMOKE_CASES[@]}"; do
    "${BASH_SOURCE[0]}" "${smoke_case}"
  done
}

case "${1:-bookstack}" in
  nextcloud | bookstack | kaneo | zulip | open-webui | grafana | langfuse)
    run_smoke "$1"
    ;;
  all)
    run_all_smokes
    ;;
  --list)
    print_cases
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
