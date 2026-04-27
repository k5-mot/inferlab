#!/usr/bin/env bash
set -euo pipefail

# 使い方とオプションを表示する。
usage() {
  cat <<'EOF'
Usage:
  bash convert.sh --image-ref IMAGE_REF [options]

Options:
  --image-ref IMAGE_REF   Image reference used by download.sh.
  --out-dir PATH          Download root directory. Default: <script-dir>/out
  --archive-dir PATH      Output archive directory. Default: <script-dir>/archive
  --force                 Overwrite the target tar if it already exists.
  --debug                 Enable bash xtrace debug output.
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

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out_root="$script_dir/out"
archive_root="$script_dir/archive"
image_ref=""
force=false
debug=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-ref)
      [[ $# -ge 2 ]] || die "missing value for --image-ref"
      image_ref=$2
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "missing value for --out-dir"
      out_root=$2
      shift 2
      ;;
    --archive-dir)
      [[ $# -ge 2 ]] || die "missing value for --archive-dir"
      archive_root=$2
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --debug)
      debug=true
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

[[ -n "$image_ref" ]] || {
  usage >&2
  exit 2
}

if [[ "$debug" == true ]]; then
  debug "bash xtrace enabled"
  set -x
fi

require_cmd jq
require_cmd tar
require_cmd sha256sum
require_cmd awk

# イメージ参照をディレクトリ名として安全な文字列へ変換する。
safe_name() {
  printf '%s' "$1" | sed 's|[/:@]|_|g; s|[^A-Za-z0-9._-]|_|g'
}

# digest (sha256:...) から 16 進部分のみを取り出す。
digest_hex() {
  local digest=$1
  printf '%s' "${digest#*:}"
}

# ファイルサイズをバイト単位で取得する。
file_size() {
  local path=$1
  wc -c < "$path" | awk '{print $1}'
}

# イメージ参照を正規化し、out/archive のキー生成情報を確定する。
parse_image_ref() {
  local raw=$1
  local first path last

  # download.sh と同じ規則で image ref を正規化し、
  # out/ 配下のディレクトリ名解決と RepoTag 生成の一貫性を保つ。

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

# 可能ならハードリンク、不可ならコピーでファイルを配置する。
link_or_copy() {
  local src=$1
  local dest=$2

  # staging では巨大 blob の二重コピーを避けたいので、まず hardlink を試す。
  ln "$src" "$dest" 2>/dev/null || cp -p "$src" "$dest"
}

parse_image_ref "$image_ref"
image_key=$(safe_name "$canonical_image_ref")
if [[ "$reference_kind" == "tag" ]]; then
  ref_name=$reference
else
  ref_name=""
fi
source_dir="${out_root}/${image_key}"
manifest_file="${source_dir}/manifest.json"
blobs_dir="${source_dir}/blobs/sha256"
target_tar="${archive_root}/${image_key}.tar"

[[ -d "$source_dir" ]] || die "download directory not found: $source_dir"
[[ -f "$manifest_file" ]] || die "manifest.json not found: $manifest_file"
[[ -d "$blobs_dir" ]] || die "blob directory not found: $blobs_dir"

# 変換処理は "download.sh が完了済み" であることを前提とする。
# 入力欠損をここで弾くことで、壊れた tar の生成を防ぐ。

mkdir -p "$archive_root"
if [[ -e "$target_tar" && "$force" != true ]]; then
  die "archive already exists: $target_tar"
fi

manifest_media_type=$(jq -r '.mediaType // empty' "$manifest_file")
config_digest=$(jq -r '.config.digest // empty' "$manifest_file")
[[ -n "$config_digest" && "$config_digest" != "null" ]] || die "manifest.json does not contain .config.digest"

missing=0
# convert.sh は out/ に必要 blob が揃っていることが前提。足りなければ tar を作らない。
while IFS=$'\t' read -r digest size role; do
  blob_path="${blobs_dir}/$(digest_hex "$digest")"
  if [[ ! -f "$blob_path" ]]; then
    echo "MISSING: ${role} ${digest}" >&2
    missing=1
    continue
  fi

  actual_size=$(file_size "$blob_path")
  if [[ "$actual_size" != "$size" ]]; then
    die "blob size mismatch for ${digest}: expected ${size}, got ${actual_size}"
  fi
done < <(
  jq -r '
    ([{
      role: "config",
      digest: .config.digest,
      size: .config.size
    }] + (.layers | map({
      role: "layer",
      digest: .digest,
      size: .size
    })))
    | .[]
    | [.digest, (.size | tostring), .role]
    | @tsv
  ' "$manifest_file"
)

[[ "$missing" -eq 0 ]] || die "not all blobs are present under ${blobs_dir}"

# index.json から参照できるよう、元 manifest 自体も blob として tar に入れる。
manifest_digest="sha256:$(sha256sum "$manifest_file" | awk '{print $1}')"
manifest_hex=$(digest_hex "$manifest_digest")
manifest_size=$(file_size "$manifest_file")

stage_dir=$(mktemp -d "${archive_root}/.convert.${image_key}.XXXXXX")
# 一時ステージングディレクトリを必ず削除する。
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "${stage_dir}/blobs/sha256"

link_or_copy "$manifest_file" "${stage_dir}/blobs/sha256/${manifest_hex}"

# config と layers を blob 配下に揃え、docker load できる最小限の OCI layout を組み立てる。
while IFS=$'\t' read -r digest; do
  link_or_copy "${blobs_dir}/$(digest_hex "$digest")" "${stage_dir}/blobs/sha256/$(digest_hex "$digest")"
done < <(jq -r '[.config.digest] + (.layers | map(.digest)) | .[]' "$manifest_file")

layers_json=$(jq -rc '[.layers[] | "blobs/sha256/\(.digest | split(":")[1])"]' "$manifest_file")
config_path="blobs/sha256/$(digest_hex "$config_digest")"

jq -n \
  --arg config "$config_path" \
  --arg tag "$repo_tag" \
  --argjson layers "$layers_json" '
    [
      {
        Config: $config,
        RepoTags: (if $tag == "" then [] else [$tag] end),
        Layers: $layers
      }
    ]
  ' > "${stage_dir}/manifest.json"

jq -n \
  --arg media_type "${manifest_media_type:-application/vnd.oci.image.manifest.v1+json}" \
  --arg digest "$manifest_digest" \
  --argjson size "$manifest_size" \
  --arg image_name "$canonical_image_ref" \
  --arg ref_name "$ref_name" '
    {
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.index.v1+json",
      manifests: [
        {
          mediaType: $media_type,
          digest: $digest,
          size: $size,
          annotations:
            ({
              "io.containerd.image.name": $image_name
            } + (if $ref_name == "" then {} else {
              "org.opencontainers.image.ref.name": $ref_name
            } end))
        }
      ]
    }
  ' > "${stage_dir}/index.json"

# docker load 互換の最小 OCI layout: manifest.json/index.json/oci-layout + blobs。
printf '%s\n' '{"imageLayoutVersion":"1.0.0"}' > "${stage_dir}/oci-layout"

tmp_tar="${target_tar}.tmp.$$"
rm -f "$tmp_tar"

# 途中失敗時に壊れた完成品を残さないよう、一時 tar へ出力してから置き換える。
log "Creating ${target_tar}"
tar -C "$stage_dir" -cf "$tmp_tar" .
mv -f "$tmp_tar" "$target_tar"

trap - EXIT
rm -rf "$stage_dir"

log "Archive ready: ${target_tar}"
