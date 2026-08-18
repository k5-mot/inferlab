#!/usr/bin/env bash
set -euo pipefail

RPM_DIRECTORY="${RPM_DIRECTORY:-/srv/12-registry/rpm}"
DEB_DIRECTORY="${DEB_DIRECTORY:-/srv/12-registry/deb}"

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
  script/install-system-packages.sh [options]

Description:
  local directoryに保存済みのRPMまたはdeb packageをinstallします。
  dnf/yum環境ではRPM、apt環境ではdebを使用します。

Options:
  --rpm-directory DIR  RPM package directoryです。
  --deb-directory DIR  deb package directoryです。
  -h, --help           このhelpを表示して終了します。

Environment:
  RPM_DIRECTORY  既定のRPM package directoryです。既定値: /srv/12-registry/rpm
  DEB_DIRECTORY  既定のdeb package directoryです。既定値: /srv/12-registry/deb
USAGE
}

# command line argumentを検証し、directory指定とhelp要求を処理する。
# 引数:
#   $@: scriptへ渡されたcommand line argumentです。
# 戻り値:
#   有効な引数の場合は0、未対応引数または値不足の場合は非0を返す。
# 副作用:
#   help textまたはerror messageを出力する。directory指定時は対応する変数を更新する。
parse_args() {
  while (($# > 0)); do
    case "$1" in
      --rpm-directory)
        if (($# < 2)); then
          echo "RPM directoryが指定されていません: $1" >&2
          return 1
        fi
        RPM_DIRECTORY="$2"
        shift 2
        ;;
      --rpm-directory=*)
        RPM_DIRECTORY="${1#*=}"
        shift
        ;;
      --deb-directory)
        if (($# < 2)); then
          echo "deb directoryが指定されていません: $1" >&2
          return 1
        fi
        DEB_DIRECTORY="$2"
        shift 2
        ;;
      --deb-directory=*)
        DEB_DIRECTORY="${1#*=}"
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

# root権限が必要なcommandの実行prefixを決定する。
# 引数:
#   なし。
# 戻り値:
#   sudoが必要な場合は`sudo`、root実行中なら空文字を標準出力へ返す。
# 副作用:
#   sudoが必要だが見つからない場合はerror messageを標準エラー出力へ出力する。
select_privilege_command() {
  if [[ "${EUID}" -eq 0 ]]; then
    printf '\n'
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "sudo"
    return 0
  fi

  echo "root権限が必要です。rootで実行するかsudoをインストールしてください。" >&2
  return 1
}

# 指定directoryのfile patternに一致するpackage fileを列挙する。
# 引数:
#   $1: 対象directoryです。
#   $2: file patternです。
# 戻り値:
#   directoryを検索できた場合は0、directoryが存在しない場合は非0を返す。
# 副作用:
#   見つかったfile pathを標準出力へ出力する。
find_package_files() {
  local directory="$1"
  local pattern="$2"

  if [[ ! -d "${directory}" ]]; then
    return 1
  fi

  find "${directory}" -maxdepth 1 -type f -name "${pattern}" -print
}

# RPM packageをdnfまたはyumでinstallする。
# 引数:
#   $1: 権限昇格commandです。不要な場合は空文字です。
# 戻り値:
#   install成功時は0、失敗時は非0を返す。
# 副作用:
#   system package databaseへRPM packageをinstallする。
install_rpm_packages() {
  local privilege_command="$1"
  local package_manager
  local rpm_files=()

  if command -v dnf >/dev/null 2>&1; then
    package_manager="dnf"
  elif command -v yum >/dev/null 2>&1; then
    package_manager="yum"
  else
    return 1
  fi

  mapfile -t rpm_files < <(find_package_files "${RPM_DIRECTORY}" "*.rpm")
  if ((${#rpm_files[@]} == 0)); then
    echo "RPM packageが見つかりません: ${RPM_DIRECTORY}/*.rpm" >&2
    return 1
  fi

  if [[ -n "${privilege_command}" ]]; then
    "${privilege_command}" "${package_manager}" install -y "${rpm_files[@]}"
  else
    "${package_manager}" install -y "${rpm_files[@]}"
  fi
}

# deb packageをapt-getでinstallする。
# 引数:
#   $1: 権限昇格commandです。不要な場合は空文字です。
# 戻り値:
#   install成功時は0、失敗時は非0を返す。
# 副作用:
#   system package databaseへdeb packageをinstallする。
install_deb_packages() {
  local privilege_command="$1"
  local deb_files=()

  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi

  mapfile -t deb_files < <(find_package_files "${DEB_DIRECTORY}" "*.deb")
  if ((${#deb_files[@]} == 0)); then
    echo "deb packageが見つかりません: ${DEB_DIRECTORY}/*.deb" >&2
    return 1
  fi

  if [[ -n "${privilege_command}" ]]; then
    "${privilege_command}" apt-get install -y "${deb_files[@]}"
  else
    apt-get install -y "${deb_files[@]}"
  fi
}

parse_args "$@"
privilege_command="$(select_privilege_command)"

if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  install_rpm_packages "${privilege_command}"
elif command -v apt-get >/dev/null 2>&1; then
  install_deb_packages "${privilege_command}"
else
  echo "dnf、yum、apt-getのいずれも見つかりません。" >&2
  exit 1
fi
