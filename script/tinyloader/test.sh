#!/usr/bin/env bash
set -euo pipefail

# 使い方とオプションを表示する。
usage() {
  cat <<'EOF'
Usage:
  bash test.sh [options]

Options:
  --image-ref IMAGE_REF   Image reference to test.
                          If omitted, run all sample images:
                          docker.io/library/hello-world:latest
                          quay.io/podman/hello:latest
                          ghcr.io/jonashackt/hello-world:latest
  --part-size-gb SIZE     Same value passed to download.sh. Default: 4
  --platform PLATFORM     Target platform. Default: linux/amd64
  --work-dir PATH         Root directory that will receive out/ and archive/.
                          Default: <script-dir>
  --skip-load             Stop after convert.sh. Do not run docker load -i.
  -h, --help              Show this help.
EOF
}

if [[ -t 2 ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_DEBUG=$'\033[36m'
  COLOR_INFO=$'\033[32m'
  COLOR_WARN=$'\033[33m'
  COLOR_ERROR=$'\033[31m'
else
  COLOR_RESET=""
  COLOR_DEBUG=""
  COLOR_INFO=""
  COLOR_WARN=""
  COLOR_ERROR=""
fi

# ログレベル付きメッセージを整形して出力する。
print_level() {
  local level=$1
  local color=$2
  local stream=$3
  shift 3

  local ts
  ts=$(date -u '+%H:%M:%S')
  if [[ "$stream" == "stdout" ]]; then
    printf '[%s] %b%s%b %s\n' "$ts" "$color" "$level" "$COLOR_RESET" "$*"
  else
    printf '[%s] %b%s%b %s\n' "$ts" "$color" "$level" "$COLOR_RESET" "$*" >&2
  fi
}

# エラーメッセージを表示して終了する。
die() {
  print_level "ERROR" "$COLOR_ERROR" stderr "$*"
  exit 1
}

# タイムスタンプ付きの通常ログを出力する。
log() {
  print_level "INFO" "$COLOR_INFO" stdout "$*"
}

# デバッグメッセージを標準エラーへ出力する。
debug() {
  print_level "DEBUG" "$COLOR_DEBUG" stderr "$*"
}

# 警告メッセージを標準エラーへ出力する。
warn() {
  print_level "WARN" "$COLOR_WARN" stderr "$*"
}

# 必須コマンドの存在を検証する。
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# イメージ参照をディレクトリ名として安全な文字列へ変換する。
safe_name() {
  printf '%s' "$1" | sed 's|[/:@]|_|g; s|[^A-Za-z0-9._-]|_|g'
}

# イメージ参照を正規化し、タグ検証用の情報を確定する。
parse_image_ref() {
  local raw=$1
  local first path last

  # download/convert と同じ正規化ロジックを使い、
  # テスト時の期待タグ判定 (docker image inspect) と整合させる。

  first=${raw%%/*}
  if [[ "$raw" == */* ]] && [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    registry=$first
    path=${raw#*/}
  else
    registry="docker.io"
    path=$raw
  fi

  if [[ "$path" == *@* ]]; then
    reference=${path##*@}
    repository=${path%@*}
    reference_kind="digest"
  else
    last=${path##*/}
    if [[ "$last" == *:* ]]; then
      reference=${path##*:}
      repository=${path%:*}
    else
      reference="latest"
      repository=$path
    fi
    reference_kind="tag"
  fi

  [[ -n "$repository" ]] || die "could not parse repository from image ref: $raw"

  if [[ "$registry" == "docker.io" && "$repository" != */* ]]; then
    repository="library/$repository"
  fi

  if [[ "$reference_kind" == "digest" ]]; then
    canonical_image_ref="${registry}/${repository}@${reference}"
    repo_tag=""
  else
    canonical_image_ref="${registry}/${repository}:${reference}"
    repo_tag="$canonical_image_ref"
  fi
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
download_script="${script_dir}/download.sh"
convert_script="${script_dir}/convert.sh"
image_ref=""
part_size_gb="4"
platform="linux/amd64"
work_dir="$script_dir"
skip_load=false
image_ref_specified=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-ref)
      [[ $# -ge 2 ]] || die "missing value for --image-ref"
      image_ref=$2
      image_ref_specified=true
      shift 2
      ;;
    --part-size-gb)
      [[ $# -ge 2 ]] || die "missing value for --part-size-gb"
      part_size_gb=$2
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || die "missing value for --platform"
      platform=$2
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "missing value for --work-dir"
      work_dir=$2
      shift 2
      ;;
    --skip-load)
      skip_load=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_cmd bash
require_cmd jq
if [[ "$skip_load" != true ]]; then
  require_cmd docker
fi

[[ -x "$download_script" || -f "$download_script" ]] || die "download.sh not found: $download_script"
[[ -x "$convert_script" || -f "$convert_script" ]] || die "convert.sh not found: $convert_script"

if [[ "$image_ref_specified" == true ]]; then
  test_images=("$image_ref")
else
  # --image-ref 未指定時は主要 public registry のサンプルを順に検証する。
  test_images=(
    "docker.io/library/hello-world:latest"
    "quay.io/podman/hello:latest"
    "ghcr.io/jonashackt/hello-world:latest"
  )
fi

# 単一イメージの download→convert→(必要なら load) を実行する。
run_single_test() {
  local test_image_ref=$1
  local image_key out_root archive_root stash_root stash_dir image_dir blobs_dir archive_path
  local attempt status moved blob_path blob_name restore_path

  parse_image_ref "$test_image_ref"
  image_key=$(safe_name "$canonical_image_ref")

  out_root="${work_dir}/out"
  archive_root="${work_dir}/archive"
  # README の「手動で別の場所へ退避する」操作を自動化するための一時退避先。
  stash_root="${work_dir}/.test-stash"
  stash_dir="${stash_root}/${image_key}"
  image_dir="${out_root}/${image_key}"
  blobs_dir="${image_dir}/blobs/sha256"
  archive_path="${archive_root}/${image_key}.tar"

  mkdir -p "$out_root" "$archive_root" "$stash_dir"

  # download.sh は quota 到達で exit 20 を返すため、
  # このループで退避・再実行を繰り返して最終完了まで持っていく。
  attempt=1
  while true; do
    log "Running download attempt ${attempt} for ${test_image_ref}"
    set +e
    bash "$download_script" \
      --image-ref "$test_image_ref" \
      --part-size-gb "$part_size_gb" \
      --platform "$platform" \
      --out-dir "$out_root"
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      break
    fi

    if [[ "$status" -ne 20 ]]; then
      die "download.sh failed for ${test_image_ref} with exit code ${status}. Output root: ${work_dir}"
    fi

    moved=0
    if [[ -d "$blobs_dir" ]]; then
      # quota 到達時はいったん blob を退避させ、再実行で続きから取得できることを検証する。
      while IFS= read -r -d '' blob_path; do
        blob_name=$(basename "$blob_path")
        if [[ -e "${stash_dir}/${blob_name}" ]]; then
          die "stash already contains ${blob_name}. Remove ${stash_dir} and retry."
        fi
        mv "$blob_path" "${stash_dir}/${blob_name}"
        moved=$((moved + 1))
      done < <(find "$blobs_dir" -maxdepth 1 -type f -print0)
    fi

    (( moved > 0 )) || die "download.sh paused for ${test_image_ref} but no blob files were available to stash. Output root: ${work_dir}"
    log "Stashed ${moved} blob(s); resuming download for ${test_image_ref}"
    attempt=$((attempt + 1))
  done

  mkdir -p "$blobs_dir"
  if find "$stash_dir" -maxdepth 1 -type f | read -r _; then
    # convert.sh では blob 一式が必要なので、最後に退避分を out/ へ戻してから変換する。
    while IFS= read -r -d '' blob_path; do
      restore_path="${blobs_dir}/$(basename "$blob_path")"
      if [[ ! -e "$restore_path" ]]; then
        cp "$blob_path" "$restore_path"
      fi
    done < <(find "$stash_dir" -maxdepth 1 -type f -print0)
  fi
  rm -rf "$stash_dir"
  rmdir "$stash_root" 2>/dev/null || true

  # 実運用と同じく、download.sh の成果物をそのまま convert.sh に渡して archive を作る。
  log "Running convert.sh for ${test_image_ref}"
  bash "$convert_script" \
    --image-ref "$test_image_ref" \
    --out-dir "$out_root" \
    --archive-dir "$archive_root" \
    --force

  if [[ "$skip_load" == true ]]; then
    log "Test complete for ${test_image_ref}. Results: ${out_root} / ${archive_path}"
    return
  fi

  # 最後は docker load まで通し、生成 tar が実際に取り込めることを確認する。
  log "Loading archive into Docker for ${test_image_ref}"
  docker load -i "$archive_path" >/dev/null

  if [[ -n "$repo_tag" ]]; then
    docker image inspect "$repo_tag" >/dev/null 2>&1 || die "docker load finished, but the expected tag was not found: $repo_tag"
  fi

  log "Test complete for ${test_image_ref}. Results: ${out_root} / ${archive_path}"
}

for test_image in "${test_images[@]}"; do
  # 1 画像ずつ独立して処理し、どの registry で失敗したか切り分けやすくする。
  run_single_test "$test_image"
done

log "All requested tests completed. Results root: ${work_dir}"
