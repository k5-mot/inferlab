#!/usr/bin/env bash
set -euo pipefail

VSIX_DIRECTORY="${VSIX_DIRECTORY:-/srv/12-registry/vsix}"
EDITOR_COMMAND="${EDITOR_COMMAND:-}"

# scriptの利用方法を標準出力へ表示する。
# 引数:
#   なし。
# 戻り値:
#   常に0を返す。
# 副作用:
#   help textを標準出力へ出力する。
print_usage() {
  cat <<'USAGE'
Usage:
  12-registry/scripts/install-vscode-extensions.sh [options]

Description:
  local directoryに保存済みのVSIX fileをVS Code互換CLIへinstallします。

Options:
  --vsix-directory DIR  VSIX file directoryです。
  --editor-command CMD  使用するVS Code互換CLIです。
  -h, --help            このhelpを表示して終了します。

Environment:
  VSIX_DIRECTORY  既定のVSIX file directoryです。既定値: /srv/12-registry/vsix
  EDITOR_COMMAND  code、code-server、codiumなどのCLI commandです。
USAGE
}

# command line argumentを検証し、directoryやeditor command指定を処理する。
# 引数:
#   $@: scriptへ渡されたcommand line argumentです。
# 戻り値:
#   有効な引数の場合は0、未対応引数または値不足の場合は非0を返す。
# 副作用:
#   help textまたはerror messageを出力する。指定時は`VSIX_DIRECTORY`または`EDITOR_COMMAND`を更新する。
parse_args() {
  while (($# > 0)); do
    case "$1" in
      --vsix-directory)
        if (($# < 2)); then
          echo "VSIX directoryが指定されていません: $1" >&2
          return 1
        fi
        VSIX_DIRECTORY="$2"
        shift 2
        ;;
      --vsix-directory=*)
        VSIX_DIRECTORY="${1#*=}"
        shift
        ;;
      --editor-command)
        if (($# < 2)); then
          echo "editor commandが指定されていません: $1" >&2
          return 1
        fi
        EDITOR_COMMAND="$2"
        shift 2
        ;;
      --editor-command=*)
        EDITOR_COMMAND="${1#*=}"
        shift
        ;;
      -h | --help)
        print_usage
        exit 0
        ;;
      *)
        echo "未対応の引数です: $1" >&2
        echo "helpを表示するには -h または --help を指定してください。" >&2
        return 1
        ;;
    esac
  done
}

# VS Code互換CLI commandを決定する。
# 引数:
#   なし。
# 戻り値:
#   使用するCLI command名を標準出力へ返す。見つからない場合は非0を返す。
# 副作用:
#   指定commandが存在しない場合はerror messageを標準エラー出力へ出力する。
select_editor_command() {
  local candidates=(code code-server codium code-insiders)
  local candidate

  if [[ -n "${EDITOR_COMMAND}" ]]; then
    if command -v "${EDITOR_COMMAND}" >/dev/null 2>&1; then
      printf '%s\n' "${EDITOR_COMMAND}"
      return 0
    fi

    echo "指定されたeditor commandが見つかりません: ${EDITOR_COMMAND}" >&2
    return 1
  fi

  for candidate in "${candidates[@]}"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  echo "VS Code互換CLIが見つかりません。--editor-commandで指定してください。" >&2
  return 1
}

# VSIX fileをVS Code互換CLIへinstallする。
# 引数:
#   $1: VS Code互換CLI commandです。
# 戻り値:
#   すべてinstallできた場合は0、VSIXが存在しない場合またはinstall失敗時は非0を返す。
# 副作用:
#   editorのextension directoryへ拡張機能をinstallする。
install_vsix_extensions() {
  local editor_command="$1"
  local vsix_files=()
  local vsix_file

  if [[ ! -d "${VSIX_DIRECTORY}" ]]; then
    echo "VSIX directoryが見つかりません: ${VSIX_DIRECTORY}" >&2
    return 1
  fi

  shopt -s nullglob
  vsix_files=("${VSIX_DIRECTORY}"/*.vsix)
  shopt -u nullglob

  if ((${#vsix_files[@]} == 0)); then
    echo "VSIX fileが見つかりません: ${VSIX_DIRECTORY}/*.vsix" >&2
    return 1
  fi

  for vsix_file in "${vsix_files[@]}"; do
    echo "Install VSIX ${vsix_file}"
    "${editor_command}" --install-extension "${vsix_file}" --force
  done
}

parse_args "$@"
editor_command="$(select_editor_command)"
install_vsix_extensions "${editor_command}"
