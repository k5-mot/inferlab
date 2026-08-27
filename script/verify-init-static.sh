#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${REPO_ROOT}"

export PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
: "${STACK_NAME:?STACK_NAME is required}"
export STACK_NAME
export DIFY_INIT_PASSWORD="${DIFY_INIT_PASSWORD:-admin}"
export PYTHONDONTWRITEBYTECODE=1

# 追跡済みshell scriptの構文を検証する。
# 引数:
#   なし。
# 戻り値:
#   すべてのshell scriptが構文検証を通過した場合は0、失敗した場合は非0を返す。
# 副作用:
#   検証対象のfile pathを標準出力へ表示する。
verify_shell_syntax() {
  local shell_files=()
  mapfile -t shell_files < <(
    git ls-files '*.sh' \
      ':!:10-inference/hermes-agent/lazy-packages/**' \
      ':!:node_modules/**' \
      ':!:.venv/**' |
      while IFS= read -r tracked_file; do
        [[ -f "${tracked_file}" ]] && printf '%s\n' "${tracked_file}"
      done
  )

  if ((${#shell_files[@]} == 0)); then
    echo "shell syntax: no tracked shell files"
    return 0
  fi

  echo "shell syntax: ${#shell_files[@]} files"
  bash -n "${shell_files[@]}"
}

# 追跡済みPython scriptの構文を検証する。
# 引数:
#   なし。
# 戻り値:
#   すべてのPython scriptがcompile可能な場合は0、失敗した場合は非0を返す。
# 副作用:
#   `PYTHONDONTWRITEBYTECODE=1`により`__pycache__`生成を抑止する。
verify_python_syntax() {
  local python_files=()
  mapfile -t python_files < <(
    git ls-files '*.py' \
      ':!:10-inference/hermes-agent/lazy-packages/**' \
      ':!:node_modules/**' \
      ':!:.venv/**' |
      while IFS= read -r tracked_file; do
        [[ -f "${tracked_file}" ]] && printf '%s\n' "${tracked_file}"
      done
  )

  if ((${#python_files[@]} == 0)); then
    echo "python syntax: no tracked python files"
    return 0
  fi

  echo "python syntax: ${#python_files[@]} files"
  python3 -m py_compile "${python_files[@]}"
}

# 追跡済みJavaScript scriptの構文を検証する。
# 引数:
#   なし。
# 戻り値:
#   Node.jsが未導入の場合は検証をskipして0、構文検証に失敗した場合は非0を返す。
# 副作用:
#   検証対象のfile pathを標準出力へ表示する。scriptは実行しない。
verify_javascript_syntax() {
  local javascript_files=()
  mapfile -t javascript_files < <(
    git ls-files '*.js' '*.cjs' '*.mjs' \
      ':!:10-inference/hermes-agent/lazy-packages/**' \
      ':!:node_modules/**' \
      ':!:.venv/**' |
      while IFS= read -r tracked_file; do
        [[ -f "${tracked_file}" ]] && printf '%s\n' "${tracked_file}"
      done
  )

  if ((${#javascript_files[@]} == 0)); then
    echo "javascript syntax: no tracked javascript files"
    return 0
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "javascript syntax: skipped because node is not installed"
    return 0
  fi

  echo "javascript syntax: ${#javascript_files[@]} files"
  local javascript_file
  for javascript_file in "${javascript_files[@]}"; do
    node --check "${javascript_file}"
  done
}

# Difyの認証設定がKeycloakへ再接続されていないことを検証する。
# 引数:
#   なし。
# 戻り値:
#   Dify向けOIDC設定が無い場合は0、残存する場合は非0を返す。
# 副作用:
#   残存する設定file pathと内容を標準エラー出力へ表示する。
verify_dify_local_authentication() {
  local forbidden_patterns=(
    'DIFY_OIDC_CLIENT_SECRET'
    'clientId:[[:space:]]*dify'
    '32100/console/api/oauth/authorize/keycloak'
  )
  local pattern

  for pattern in "${forbidden_patterns[@]}"; do
    if git grep -n -E "${pattern}" -- . ':!script/verify-init-static.sh' >&2; then
      echo "Dify向けKeycloak/OIDC設定が残っています: ${pattern}" >&2
      return 1
    fi
  done
}

# Difyのair-gap設定と固定plugin inventoryを検証する。
# 引数:
#   なし。
# 戻り値:
#   外部接続設定が無くplugin lockが期待値と一致する場合は0、違反がある場合は非0を返す。
# 副作用:
#   違反した設定または不足した必須設定を標準エラー出力へ表示する。
verify_dify_airgap_configuration() {
  local compose_file="21-dify/docker-compose.yml"
  local lock_file="21-dify/plugins/plugins.lock.json"
  local forbidden_patterns=(
    'marketplace\.dify\.ai'
    'updates\.dify\.ai'
    'api\.openai\.com'
    '1\.1\.1\.1'
    '8\.8\.8\.8'
    'MARKETPLACE_ENABLED:[[:space:]]*"?true'
    'ENABLE_NETWORK:[[:space:]]*"?true'
    'PIP_MIRROR_AUTO_DETECT:[[:space:]]*"?true'
    'dify-ssrf-proxy'
  )
  local required_patterns=(
    'INIT_PASSWORD: ${DIFY_INIT_PASSWORD:-admin}'
    'CHECK_UPDATE_URL: ""'
    'OPENAI_API_BASE: http://litellm:4000/v1'
    'DISABLE_TELEMETRY: "true"'
    'DO_NOT_TRACK: "true"'
    'TELEMETRY_ENDPOINT: ""'
    'TELEMETRY_FALLBACK_ENDPOINT: ""'
    'MARKETPLACE_ENABLED: "false"'
    'ENABLE_WEBSITE_JINAREADER: "false"'
    'ENABLE_WEBSITE_FIRECRAWL: "false"'
    'ENABLE_WEBSITE_WATERCRAWL: "false"'
    'HOSTED_FETCH_APP_TEMPLATES_MODE: builtin'
    'HOSTED_FETCH_PIPELINE_TEMPLATES_MODE: builtin'
    'ENABLE_CHECK_UPGRADABLE_PLUGIN_TASK: "false"'
    'FORCE_VERIFYING_SIGNATURE: "true"'
    'PIP_MIRROR_AUTO_DETECT: "false"'
    'PIP_MIRROR_URL: http://pypiserver:8080/simple/'
    'PIP_TRUSTED_HOST: pypiserver'
    'UV_INSECURE_HOST: pypiserver'
    'ENABLE_NETWORK: "false"'
  )
  local pattern

  for pattern in "${forbidden_patterns[@]}"; do
    if grep -n -E "${pattern}" "${compose_file}" >&2; then
      echo "Difyのair-gap禁止設定が見つかりました: ${pattern}" >&2
      return 1
    fi
  done

  for pattern in "${required_patterns[@]}"; do
    if ! grep -q -F "${pattern}" "${compose_file}"; then
      echo "Difyのair-gap必須設定がありません: ${pattern}" >&2
      return 1
    fi
  done

  python3 -c 'import json, pathlib, sys; data=json.loads(pathlib.Path(sys.argv[1]).read_text()); plugins=data.get("plugins", []); expected={"id":"langgenius/openai_api_compatible","version":"0.0.64","sha256":"53c6b590f99ed0a9e8d8dcb435afc3700826fd1ac1493d7e255916fabc6679d2","requirementsSha256":"893906c1f3b3e26afbf186fe68fb8ca517a2e4b72458947b10e6ec03c5d4f278"}; sys.exit(0 if data.get("schemaVersion") == 1 and len(plugins) == 1 and all(plugins[0].get(key) == value for key, value in expected.items()) else 1)' "${lock_file}"
}

# root Compose構成と主要profileの解決結果を検証する。
# 引数:
#   なし。
# 戻り値:
#   Compose configが解決できる場合は0、失敗した場合は非0を返す。
# 副作用:
#   Docker daemonへread-onlyなconfig解決を要求する。containerは起動しない。
verify_compose_config() {
  local profiles=(
    common
    keycloak
    pubnet
    inference
    rag
    registry
    owui
    dify
    ragflow
    nextcloud
    xwiki
    kaneo
    zulip
    gitlab
    wikijs
    obsidian
    o11y
    langfuse
  )
  local profile

  echo "compose config: all includes"
  docker compose config >/dev/null

  for profile in "${profiles[@]}"; do
    echo "compose config: profile=${profile}"
    docker compose --profile "${profile}" config --services >/dev/null
  done
}

verify_shell_syntax
verify_python_syntax
verify_javascript_syntax
verify_dify_local_authentication
verify_dify_airgap_configuration
tests/e2e/test-run-playwright-smoke.sh
verify_compose_config
