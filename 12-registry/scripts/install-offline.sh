#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 次のいずれの配置でも転送後に同じ手順で実行できるようにする。
#   /transfer/install-offline.sh + /transfer/offline-bundle/
# または
#   /transfer/offline-bundle/install-offline.sh + 同じディレクトリのtarget.env
if [[ -f "$SCRIPT_DIR/target.env" ]]; then
  DEFAULT_BUNDLE_DIR="$SCRIPT_DIR"
else
  DEFAULT_BUNDLE_DIR="$SCRIPT_DIR/offline-bundle"
fi

BUNDLE_DIR="${1:-$DEFAULT_BUNDLE_DIR}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CREATE_VENV="${CREATE_VENV:-1}"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv-offline}"

# エラーメッセージを標準エラーへ出力して処理を中止する。
# 引数: $@ は出力するエラーメッセージ。
# 戻り値: 戻らず、終了コード1でスクリプトを終了する。
fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# 必須コマンドがPATHから実行可能であることを確認する。
# 引数: $1 は確認するコマンド名。
# 戻り値: コマンドが存在する場合は0。存在しない場合はfailで終了する。
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

[[ -d "$BUNDLE_DIR" ]] || fail "Bundle directory not found: $BUNDLE_DIR"
[[ -f "$BUNDLE_DIR/target.env" ]] || fail "target.env not found in: $BUNDLE_DIR"
[[ -f "$BUNDLE_DIR/python/requirements.in" ]] || fail "Python requirements not found"
[[ -d "$BUNDLE_DIR/python/wheelhouse" ]] || fail "Python wheelhouse not found"
[[ -f "$BUNDLE_DIR/npm/package.json" ]] || fail "npm package.json not found"
[[ -f "$BUNDLE_DIR/npm/package-lock.json" ]] || fail "npm package-lock.json not found"
[[ -d "$BUNDLE_DIR/npm/cache" ]] || fail "npm cache not found"

# shellcheck disable=SC1091
source "$BUNDLE_DIR/target.env"

require_cmd "$PYTHON_BIN"
require_cmd node
require_cmd npm
require_cmd uname

# -----------------------------------------------------------------------------
# 対象アーキテクチャ、Python、glibcの検証
# -----------------------------------------------------------------------------

case "$(uname -m)" in
  x86_64) HOST_NPM_CPU="x64" ;;
  aarch64|arm64) HOST_NPM_CPU="arm64" ;;
  *) HOST_NPM_CPU="unknown" ;;
esac

[[ "$NPM_OS" == "linux" ]] || fail "Bundle was not built for Linux: NPM_OS=$NPM_OS"
[[ "$HOST_NPM_CPU" == "$NPM_CPU" ]] || fail "CPU mismatch: bundle=$NPM_CPU host=$(uname -m)"

HOST_PYTHON_VERSION="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
[[ "$HOST_PYTHON_VERSION" == "$PYTHON_VERSION" ]] || \
  fail "Python minor version mismatch: bundle=$PYTHON_VERSION host=$HOST_PYTHON_VERSION"

if command -v getconf >/dev/null 2>&1; then
  GLIBC_TEXT="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
  if [[ "$GLIBC_TEXT" =~ glibc[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
    HOST_GLIBC_MAJOR="${BASH_REMATCH[1]}"
    HOST_GLIBC_MINOR="${BASH_REMATCH[2]}"
    if (( HOST_GLIBC_MAJOR < TARGET_GLIBC_MAJOR )) || \
       (( HOST_GLIBC_MAJOR == TARGET_GLIBC_MAJOR && HOST_GLIBC_MINOR < TARGET_GLIBC_MINOR )); then
      fail "glibc is too old: bundle requires >= ${TARGET_GLIBC_MAJOR}.${TARGET_GLIBC_MINOR}, host=${HOST_GLIBC_MAJOR}.${HOST_GLIBC_MINOR}"
    fi
  else
    echo "WARNING: Could not determine glibc version; continuing." >&2
  fi
else
  echo "WARNING: getconf not found; glibc compatibility was not verified." >&2
fi

# -----------------------------------------------------------------------------
# 転送データの完全性検証
# -----------------------------------------------------------------------------

if [[ -f "$BUNDLE_DIR/SHA256SUMS.txt" ]]; then
  require_cmd sha256sum
  echo "==> Verifying SHA-256 manifest"
  (
    cd "$BUNDLE_DIR"
    sha256sum -c SHA256SUMS.txt
  )
fi

# -----------------------------------------------------------------------------
# Pythonパッケージのオフラインインストール
# -----------------------------------------------------------------------------

if [[ "$CREATE_VENV" == "1" ]]; then
  echo "==> Creating/reusing Python venv: $VENV_DIR"
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR" || \
      fail "venv creation failed. Install the OS's Python venv support beforehand, or run with CREATE_VENV=0."
  fi
  PYTHON="$VENV_DIR/bin/python"
else
  PYTHON="$PYTHON_BIN"
fi

"$PYTHON" -m pip --version >/dev/null 2>&1 || fail "pip is not available for $PYTHON"

echo "==> Installing Python bootstrap tools from wheelhouse"
"$PYTHON" -m pip install \
  --no-index \
  --find-links "$BUNDLE_DIR/python/wheelhouse" \
  pip setuptools wheel

echo "==> Installing Python packages offline"
"$PYTHON" -m pip install \
  --no-index \
  --find-links "$BUNDLE_DIR/python/wheelhouse" \
  --only-binary=:all: \
  -r "$BUNDLE_DIR/python/requirements.in"

# -----------------------------------------------------------------------------
# npmパッケージのオフラインインストール
# -----------------------------------------------------------------------------

NPM_WORK_DIR="${NPM_WORK_DIR:-$SCRIPT_DIR/npm-offline-project}"
mkdir -p "$NPM_WORK_DIR"
cp -f "$BUNDLE_DIR/npm/package.json" "$NPM_WORK_DIR/package.json"
cp -f "$BUNDLE_DIR/npm/package-lock.json" "$NPM_WORK_DIR/package-lock.json"

# 古いモジュールの影響を除き、npm ciの再現性を保つ。
rm -rf "$NPM_WORK_DIR/node_modules"

pushd "$NPM_WORK_DIR" >/dev/null

echo "==> Installing npm packages offline"
npm ci \
  --offline \
  --include=optional \
  --os=linux \
  "--cpu=$NPM_CPU" \
  --libc=glibc \
  "--cache=$BUNDLE_DIR/npm/cache" \
  --audit=false \
  --fund=false

popd >/dev/null

# -----------------------------------------------------------------------------
# インストール結果の検証
# -----------------------------------------------------------------------------

echo "==> Verification"
"$PYTHON" -m pip check
(
  cd "$NPM_WORK_DIR"
  npm ls --all --offline >/dev/null
)

echo
echo "Offline installation completed successfully."
echo "Python environment : $PYTHON"
echo "npm project        : $NPM_WORK_DIR"
echo
echo "Note: @playwright/test is installed, but Playwright browser binaries and"
echo "their OS-level libraries are separate artifacts and are not installed by this script."
