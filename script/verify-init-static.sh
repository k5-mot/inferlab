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
      ':!:.venv/**'
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
      ':!:.venv/**'
  )

  if ((${#python_files[@]} == 0)); then
    echo "python syntax: no tracked python files"
    return 0
  fi

  echo "python syntax: ${#python_files[@]} files"
  python3 -m py_compile "${python_files[@]}"
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
verify_compose_config
