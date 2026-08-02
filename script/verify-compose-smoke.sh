#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SMOKE_CASE="${1:-}"

cd "${REPO_ROOT}"

if [[ -z "${SMOKE_CASE}" ]]; then
  echo "Usage: $0 {bookstack-init|dify-postgres-init|oikb-bucket-init|langfuse-bucket-init|gitea-keycloak-init}" >&2
  exit 2
fi

readonly PROJECT_SUFFIX="${GITHUB_RUN_ID:-local}-${SMOKE_CASE}"
export STACK_NAME="${STACK_NAME:-inferlab-ci-${PROJECT_SUFFIX//[^a-zA-Z0-9-]/-}}"
export PUBLIC_HOST="${PUBLIC_HOST:-localhost}"

readonly TEMP_DIR="$(mktemp -d)"
readonly PORTLESS_OVERRIDE_FILE="${TEMP_DIR}/compose.portless.yml"

COMPOSE_BASE_ARGS=(-f docker-compose.yml -f "${PORTLESS_OVERRIDE_FILE}")
COMPOSE_ARGS=()

# smoke検証に不要な公開portを無効化するCompose overrideを作成する。
# 引数:
#   なし。
# 戻り値:
#   override fileの作成に成功した場合は0、失敗した場合は非0を返す。
# 副作用:
#   一時directory配下にCompose override fileを作成する。
write_portless_override() {
  cat >"${PORTLESS_OVERRIDE_FILE}" <<'YAML'
services:
  oidc-discovery-smoke:
    image: docker.io/library/python:3.13-alpine
    profiles:
      - gitea
    networks:
      - internal-nw
    command:
      - sh
      - -euc
      - |
        mkdir -p /tmp/oidc/realms/inferlab/.well-known /tmp/oidc/realms/inferlab/protocol/openid-connect
        cat >/tmp/oidc/realms/inferlab/.well-known/openid-configuration <<'JSON'
        {
          "issuer": "http://oidc-discovery-smoke:8080/realms/inferlab",
          "authorization_endpoint": "http://oidc-discovery-smoke:8080/realms/inferlab/protocol/openid-connect/auth",
          "token_endpoint": "http://oidc-discovery-smoke:8080/realms/inferlab/protocol/openid-connect/token",
          "userinfo_endpoint": "http://oidc-discovery-smoke:8080/realms/inferlab/protocol/openid-connect/userinfo",
          "jwks_uri": "http://oidc-discovery-smoke:8080/realms/inferlab/protocol/openid-connect/certs",
          "response_types_supported": ["code"],
          "subject_types_supported": ["public"],
          "id_token_signing_alg_values_supported": ["RS256"]
        }
        JSON
        printf '{"keys":[]}\n' >/tmp/oidc/realms/inferlab/protocol/openid-connect/certs
        cd /tmp/oidc
        exec python -m http.server 8080
    healthcheck:
      test:
        - CMD
        - python
        - -c
        - "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/realms/inferlab/.well-known/openid-configuration', timeout=3).read()"
      interval: 1s
      timeout: 3s
      retries: 30
  gitea-keycloak-init:
    environment:
      GITEA_OIDC_DISCOVERY_URL: http://oidc-discovery-smoke:8080/realms/inferlab/.well-known/openid-configuration
    depends_on:
      oidc-discovery-smoke:
        condition: service_healthy
  gitea:
    ports: !reset []
  oikb-rustfs:
    ports: !reset []
  langfuse-rustfs:
    ports: !reset []
YAML
}

# CI用の一時Compose projectを削除する。
# 引数:
#   なし。
# 戻り値:
#   cleanup成功時は0。失敗しても呼び出し元の終了理由を潰さないため、trap内では無視する。
# 副作用:
#   `STACK_NAME`で隔離されたcontainer、network、volumeを削除する。
cleanup_project() {
  docker compose "${COMPOSE_BASE_ARGS[@]}" "${COMPOSE_ARGS[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${TEMP_DIR}"
}

# 指定したserviceが終了するまで、必要なprofileだけでComposeを起動する。
# 引数:
#   $1: 終了codeを検証するservice名。
#   $2以降: `docker compose`へ渡すprofile引数。
# 戻り値:
#   対象serviceが0で終了した場合は0、失敗した場合は非0を返す。
# 副作用:
#   `STACK_NAME`で隔離されたcontainer、network、volumeを作成する。
run_exit_service() {
  local service="$1"
  shift
  COMPOSE_ARGS=("$@")
  trap cleanup_project EXIT
  docker compose "${COMPOSE_BASE_ARGS[@]}" "${COMPOSE_ARGS[@]}" up --abort-on-container-exit --exit-code-from "${service}" "${service}"
}

write_portless_override

case "${SMOKE_CASE}" in
  bookstack-init)
    # BookStack本体は起動せず、custom init scriptのvolumeコピーだけを確認する。
    run_exit_service bookstack-custom-init --profile bookstack
    ;;
  dify-postgres-init)
    # Dify全体は起動せず、PostgreSQLとplugin DB作成serviceだけを確認する。
    run_exit_service dify-postgres-init --profile dify
    ;;
  oikb-bucket-init)
    # Open WebUI本体は起動せず、RustFSとbucket初期化serviceだけを確認する。
    run_exit_service oikb-rustfs-bucket-init --profile owui --profile nextcloud
    ;;
  langfuse-bucket-init)
    # Langfuse本体は起動せず、RustFSとbucket初期化serviceだけを確認する。
    run_exit_service langfuse-rustfs-bucket-init --profile langfuse
    ;;
  gitea-keycloak-init)
    # Keycloak本体は起動せず、GiteaとOAuth source同期serviceだけを確認する。
    run_exit_service gitea-keycloak-init --profile gitea
    ;;
  *)
    echo "Unknown smoke case: ${SMOKE_CASE}" >&2
    exit 2
    ;;
esac
