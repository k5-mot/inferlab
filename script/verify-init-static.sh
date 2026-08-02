#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${REPO_ROOT}"

export PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
export STACK_NAME="${STACK_NAME:-inferlab}"
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
    nextcloud
    bookstack
    kaneo
    zulip
    obsidian
    gitea
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
tests/e2e/test-run-playwright-smoke.sh
verify_compose_config
