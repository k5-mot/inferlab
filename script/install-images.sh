#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly IMAGE_DIRECTORY="${IMAGE_DIRECTORY:-${REPO_ROOT}/images}"

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
  script/install-images.sh [-h|--help]

Description:
  images/*.tar をPodmanまたはDockerへ読み込みます。
  engineはpodmanを優先し、見つからない場合はdockerを使用します。

Options:
  -h, --help    このhelpを表示して終了します。

Environment:
  IMAGE_DIRECTORY  読み込み対象のimage archive directoryです。
                   既定値: <repository-root>/images
  IMAGE_ENGINE     使用するcontainer engine commandです。
                   例: podman, docker
USAGE
}

# command line argumentを検証し、help要求を処理する。
# 引数:
#   $@: scriptへ渡されたcommand line argumentです。
# 戻り値:
#   help表示または引数なしの場合は0、未対応引数がある場合は非0を返す。
# 副作用:
#   help textまたはerror messageを標準出力または標準エラー出力へ出力し、help時はprocessを終了する。
parse_args() {
  local argument

  for argument in "$@"; do
    case "${argument}" in
      -h | --help)
        print_usage
        exit 0
        ;;
      *)
        echo "未対応の引数です: ${argument}" >&2
        echo "helpを表示するには -h または --help を指定してください。" >&2
        return 1
        ;;
    esac
  done
}

# container image archiveをloadするcontainer engineを決定する。
# 引数:
#   なし。
# 戻り値:
#   使用するcontainer engine command名を標準出力へ返す。見つからない場合は非0を返す。
# 副作用:
#   `IMAGE_ENGINE`が指定されている場合、そのcommandの存在を検証する。
select_image_engine() {
  if [[ -n "${IMAGE_ENGINE:-}" ]]; then
    if ! command -v "${IMAGE_ENGINE}" >/dev/null 2>&1; then
      echo "指定されたIMAGE_ENGINEが見つかりません: ${IMAGE_ENGINE}" >&2
      return 1
    fi
    printf '%s\n' "${IMAGE_ENGINE}"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    printf '%s\n' "podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker"
    return 0
  fi

  echo "podmanまたはdockerが見つかりません。" >&2
  return 1
}

# images directory配下のcontainer image archiveをengineへloadする。
# 引数:
#   $1: `podman`または`docker`などのcontainer engine command名。
# 戻り値:
#   すべてのarchiveをloadできた場合は0、対象がない場合またはload失敗時は非0を返す。
# 副作用:
#   local container image storeへimageを追加する。
load_image_archives() {
  local engine="$1"
  local archives=()
  local archive

  if [[ ! -d "${IMAGE_DIRECTORY}" ]]; then
    echo "images directoryが見つかりません: ${IMAGE_DIRECTORY}" >&2
    return 1
  fi

  shopt -s nullglob
  archives=("${IMAGE_DIRECTORY}"/*.tar)
  shopt -u nullglob

  if ((${#archives[@]} == 0)); then
    echo "container image archiveが見つかりません: ${IMAGE_DIRECTORY}/*.tar" >&2
    return 1
  fi

  for archive in "${archives[@]}"; do
    echo "Load ${archive}"
    "${engine}" load -i "${archive}"
  done
}

parse_args "$@"
image_engine="$(select_image_engine)"
load_image_archives "${image_engine}"
