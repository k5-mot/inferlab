#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SMOKE_CASE="${1:-}"

cd "${REPO_ROOT}"

if [[ -z "${SMOKE_CASE}" ]]; then
  echo "Usage: $0 {dify-postgres-init|oikb-bucket-init|ragflow-bucket-init|langfuse-bucket-init}" >&2
  exit 2
fi

readonly PROJECT_SUFFIX="${GITHUB_RUN_ID:-local}-${SMOKE_CASE}"
export STACK_NAME="${STACK_NAME:-ci-${PROJECT_SUFFIX//[^a-zA-Z0-9-]/-}}"
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
  oikb-rustfs:
    ports: !reset []
  langfuse-rustfs:
    ports: !reset []
  ragflow-rustfs:
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
  dify-postgres-init)
    # Dify全体は起動せず、PostgreSQLとplugin DB作成serviceだけを確認する。
    run_exit_service dify-postgres-init --profile dify
    ;;
  oikb-bucket-init)
    # Open WebUI本体は起動せず、RustFSとbucket初期化serviceだけを確認する。
    run_exit_service oikb-rustfs-init --profile owui --profile nextcloud
    ;;
  ragflow-bucket-init)
    # RAGFlow本体は起動せず、RustFSとbucket初期化serviceだけを確認する。
    run_exit_service ragflow-rustfs-bucket-init --profile ragflow
    ;;
  langfuse-bucket-init)
    # Langfuse本体は起動せず、RustFSとbucket初期化serviceだけを確認する。
    run_exit_service langfuse-rustfs-bucket-init --profile langfuse
    ;;
  *)
    echo "Unknown smoke case: ${SMOKE_CASE}" >&2
    exit 2
    ;;
esac
