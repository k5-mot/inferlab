#!/usr/bin/env bash
set -euo pipefail

# 使い方とオプションを表示する。
usage() {
  cat <<'EOF'
Usage:
  bash download.sh --image-ref IMAGE_REF [options]

Options:
  --image-ref IMAGE_REF   OCI registry image reference to download.
  --part-size-gb SIZE     Maximum local blob size budget in GiB before pausing.
                          Default: 20
  --platform PLATFORM     Target platform when the tag points to a manifest list.
                          Default: linux/amd64
  --out-dir PATH          Output root directory. Default: <script-dir>/out
  --debug                 Enable bash xtrace debug output.
  -h, --help              Show this help.

Exit codes:
  0   Complete.
  20  Paused because the local blob budget was reached.
  1   Error.
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
image_ref=""
part_size_gb="20"
platform="linux/amd64"
debug=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-ref)
      [[ $# -ge 2 ]] || die "missing value for --image-ref"
      image_ref=$2
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
    --out-dir)
      [[ $# -ge 2 ]] || die "missing value for --out-dir"
      out_root=$2
      shift 2
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

require_cmd curl
require_cmd jq
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

# バイト数を人間向けの単位付き文字列へ変換する。
bytes_to_human() {
  awk -v bytes="$1" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ")
      value = bytes + 0
      unit_index = 1
      while (value >= 1024 && unit_index < 5) {
        value /= 1024
        unit_index++
      }
      printf "%.2f %s", value, units[unit_index]
    }
  '
}

# GiB 指定値をバイト数へ変換する。
gb_to_bytes() {
  awk -v size_gb="$1" '
    BEGIN {
      if (size_gb <= 0) {
        exit 1
      }
      printf "%.0f", size_gb * 1024 * 1024 * 1024
    }
  '
}

# URL クエリ用に文字列をエンコードする。
url_encode() {
  jq -nr --arg value "$1" '$value | @uri'
}

# UTC タイムスタンプを生成する。
timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# platform 文字列を os/arch[/variant] 形式として検証し分解する。
parse_platform() {
  local raw=$1
  IFS='/' read -r platform_os platform_arch platform_variant extra <<<"$raw"
  [[ -n "${platform_os:-}" && -n "${platform_arch:-}" ]] || {
    die "platform must look like os/arch or os/arch/variant: $raw"
  }
  [[ -z "${extra:-}" ]] || die "platform has too many components: $raw"
}

# イメージ参照を正規化し、registry/repository/reference を確定する。
parse_image_ref() {
  local raw=$1
  local first path last

  # "registry/repo:tag" と "repo:tag" の両方を受け取り、内部で正規化する。
  # docker.io 省略時は library/ 補完まで行い、以降の API URL 組み立てを単純化する。

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
  else
    canonical_image_ref="${registry}/${repository}:${reference}"
  fi

  if [[ "$registry" == "docker.io" ]]; then
    # Docker Hub の API エンドポイントは docker.io 本体ではなく registry-1.docker.io。
    registry_api_host="registry-1.docker.io"
  else
    registry_api_host="$registry"
  fi
}

# レスポンスヘッダから指定ヘッダ値を抽出する。
get_header_value() {
  local header_file=$1
  local header_name=$2

  awk -v wanted="$(printf '%s' "$header_name" | tr '[:upper:]' '[:lower:]')" '
    {
      line = $0
      sub(/\r$/, "", line)
      split(line, parts, ":")
      key = tolower(parts[1])
      if (key == wanted) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  ' "$header_file"
}

# WWW-Authenticate から指定パラメータを抜き出す。
extract_auth_param() {
  local challenge=$1
  local key=$2

  printf '%s\n' "$challenge" | sed -n "s/.*${key}=\"\\([^\"]*\\)\".*/\\1/p"
}

registry_auth_header=""
last_response_headers=""
last_response_code=""

# Bearer challenge を元にトークンを取得し Authorization ヘッダを準備する。
fetch_bearer_token() {
  local challenge=$1
  local realm service scope token_url response token

  # public registry でも manifest/blob 取得時は Bearer challenge が返ることがある。
  [[ "$challenge" == [Bb]earer* ]] || die "unsupported registry authentication challenge: $challenge"

  realm=$(extract_auth_param "$challenge" realm)
  service=$(extract_auth_param "$challenge" service)
  scope=$(extract_auth_param "$challenge" scope)

  [[ -n "$realm" ]] || die "authentication realm was not present in challenge"
  if [[ -z "$scope" ]]; then
    scope="repository:${repository}:pull"
  fi

  token_url=$realm
  if [[ "$token_url" != *\?* ]]; then
    token_url+='?'
  else
    token_url+='&'
  fi

  if [[ -n "$service" ]]; then
    token_url+="service=$(url_encode "$service")&"
  fi
  token_url+="scope=$(url_encode "$scope")"

  response=$(curl -fsSL "$token_url") || die "failed to acquire bearer token from: $realm"
  token=$(printf '%s' "$response" | jq -r '.token // .access_token // empty')
  [[ -n "$token" ]] || die "registry token response did not include a token"

  registry_auth_header="Bearer $token"
}

# レジストリ API を呼び出し、必要なら認証付きで再試行する。
registry_get() {
  local url=$1
  local accept_header=$2
  local output_path=$3
  local headers curl_rc challenge
  local -a curl_args

  headers=$(mktemp)
  curl_args=(-sS -L -D "$headers" -o "$output_path" -w '%{http_code}')
  [[ -n "$accept_header" ]] && curl_args+=(-H "Accept: $accept_header")
  [[ -n "$registry_auth_header" ]] && curl_args+=(-H "Authorization: $registry_auth_header")

  set +e
  last_response_code=$(curl "${curl_args[@]}" "$url")
  curl_rc=$?
  set -e
  if [[ "$curl_rc" -ne 0 ]]; then
    rm -f "$headers"
    die "curl failed for: $url"
  fi

  if [[ "$last_response_code" == "401" ]]; then
    # 初回リクエストで challenge を受け取り、トークン取得後に 1 回だけ再試行する。
    # ここで再試行の責務を閉じることで、呼び出し側を単純に保つ。
    challenge=$(get_header_value "$headers" "www-authenticate")
    rm -f "$headers"
    [[ -n "$challenge" ]] || die "registry returned 401 without WWW-Authenticate header"
    fetch_bearer_token "$challenge"

    headers=$(mktemp)
    curl_args=(-sS -L -D "$headers" -o "$output_path" -w '%{http_code}')
    [[ -n "$accept_header" ]] && curl_args+=(-H "Accept: $accept_header")
    curl_args+=(-H "Authorization: $registry_auth_header")

    set +e
    last_response_code=$(curl "${curl_args[@]}" "$url")
    curl_rc=$?
    set -e
    if [[ "$curl_rc" -ne 0 ]]; then
      rm -f "$headers"
      die "curl failed for: $url"
    fi
  fi

  last_response_headers=$headers
  if [[ ! "$last_response_code" =~ ^2 ]]; then
    local message=""
    if [[ -f "$output_path" ]]; then
      message=$(head -c 400 "$output_path" | tr '\n' ' ')
    fi
    rm -f "$headers"
    die "registry request failed with HTTP $last_response_code: $url${message:+ :: $message}"
  fi
}

requested_manifest_digest=""
requested_manifest_media_type=""

# 参照 (tag/digest) から manifest を取得し、関連メタデータを確定する。
fetch_manifest_by_ref() {
  local ref=$1
  local target_path=$2
  local content_type
  local accept_header

  # 最初は index と単一 manifest の両方を受け付け、後段で platform を確定させる。
  accept_header="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  registry_get "https://${registry_api_host}/v2/${repository}/manifests/${ref}" "$accept_header" "$target_path"

  content_type=$(get_header_value "$last_response_headers" "content-type")
  content_type=${content_type%%;*}
  requested_manifest_digest=$(get_header_value "$last_response_headers" "docker-content-digest")
  requested_manifest_media_type=$content_type

  if [[ -z "$requested_manifest_digest" ]]; then
    requested_manifest_digest="sha256:$(sha256sum "$target_path" | awk '{print $1}')"
  fi
  if [[ -z "$requested_manifest_media_type" ]]; then
    requested_manifest_media_type=$(jq -r '.mediaType // empty' "$target_path")
  fi
}

selected_manifest_digest=""
selected_manifest_media_type=""
selected_manifest_size=""

# manifest list なら platform を解決し、最終 manifest を保存する。
resolve_manifest() {
  local request_body resolved_body selected_descriptor
  local manifest_kind

  request_body=$(mktemp)
  fetch_manifest_by_ref "$reference" "$request_body"

  manifest_kind=$(jq -r '.mediaType // empty' "$request_body")
  if [[ -z "$manifest_kind" ]]; then
    manifest_kind=$requested_manifest_media_type
  fi

  case "$manifest_kind" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      # multi-arch の場合は指定 platform だけを 1 つ選び、その manifest を保存する。
      selected_descriptor=$(jq -cer \
        --arg os "$platform_os" \
        --arg arch "$platform_arch" \
        --arg variant "${platform_variant:-}" '
          .manifests
          | map(
              select(
                (.platform.os // "") == $os and
                (.platform.architecture // "") == $arch and
                ($variant == "" or (.platform.variant // "") == $variant)
              )
            )
          | first
        ' "$request_body") || die "platform ${platform} was not found in manifest list"

      rm -f "$request_body"

      resolved_body=$(mktemp)
      fetch_manifest_by_ref "$(printf '%s' "$selected_descriptor" | jq -r '.digest')" "$resolved_body"
      selected_manifest_digest=$requested_manifest_digest
      selected_manifest_media_type=$requested_manifest_media_type
      selected_manifest_size=$(file_size "$resolved_body")
      mv "$resolved_body" "$manifest_file"
      ;;
    application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
      selected_manifest_digest=$requested_manifest_digest
      selected_manifest_media_type=$requested_manifest_media_type
      selected_manifest_size=$(file_size "$request_body")
      mv "$request_body" "$manifest_file"
      ;;
    *)
      rm -f "$request_body"
      die "unsupported manifest media type: ${manifest_kind:-unknown}"
      ;;
  esac
}

# 新規 state.json を作成し、ダウンロード対象 blob 一覧を初期化する。
write_state() {
  local now
  local tmp_state

  now=$(timestamp)
  tmp_state=$(mktemp)
  # state.json は「どの blob まで完了したか」だけを持つ。blob 実体は後で退避されてもよい。
  jq -n \
    --arg image_ref "$canonical_image_ref" \
    --arg registry "$registry" \
    --arg repository "$repository" \
    --arg reference "$reference" \
    --arg reference_kind "$reference_kind" \
    --arg platform "$platform" \
    --arg manifest_digest "$selected_manifest_digest" \
    --arg manifest_media_type "$selected_manifest_media_type" \
    --argjson manifest_size "$selected_manifest_size" \
    --arg created_at "$now" \
    --arg updated_at "$now" \
    --slurpfile manifest_json "$manifest_file" '
      {
        schema: 1,
        image_ref: $image_ref,
        registry: $registry,
        repository: $repository,
        reference: $reference,
        reference_kind: $reference_kind,
        platform: $platform,
        manifest: {
          digest: $manifest_digest,
          media_type: $manifest_media_type,
          size: $manifest_size
        },
        blobs:
          ([{
            role: "config",
            digest: $manifest_json[0].config.digest,
            size: $manifest_json[0].config.size,
            downloaded: false
          }] + ($manifest_json[0].layers | map({
            role: "layer",
            digest: .digest,
            size: .size,
            downloaded: false
          }))),
        complete: false,
        created_at: $created_at,
        updated_at: $updated_at
      }
    ' > "$tmp_state"
  mv "$tmp_state" "$state_file"
}

# 指定 digest の blob を downloaded=true に更新する。
set_blob_downloaded() {
  local digest=$1
  local now tmp_state

  now=$(timestamp)
  tmp_state=$(mktemp)
  jq \
    --arg digest "$digest" \
    --arg updated_at "$now" '
      .blobs |= map(
        if .digest == $digest then
          .downloaded = true
        else
          .
        end
      )
      | .complete = ([.blobs[].downloaded] | all)
      | .updated_at = $updated_at
    ' "$state_file" > "$tmp_state"
  mv "$tmp_state" "$state_file"
}

# 既存 state/manifest の整合を確認し、必要に応じて再生成する。
refresh_manifest_and_state() {
  if [[ -f "$state_file" ]]; then
    local existing_ref existing_platform

    existing_ref=$(jq -r '.image_ref // empty' "$state_file")
    existing_platform=$(jq -r '.platform // empty' "$state_file")
    [[ "$existing_ref" == "$canonical_image_ref" ]] || die "state.json belongs to another image: $existing_ref"
    [[ -z "$existing_platform" || "$existing_platform" == "$platform" ]] || die "state.json belongs to another platform: $existing_platform"
  fi

  if [[ ! -f "$state_file" || ! -f "$manifest_file" ]]; then
    # 初回実行、または途中で制御ファイルが欠けたケースは manifest/state を作り直す。
    log "Resolving manifest for ${canonical_image_ref} (${platform})"
    resolve_manifest
    write_state
    return
  fi

  selected_manifest_digest=$(jq -r '.manifest.digest // empty' "$state_file")
  selected_manifest_media_type=$(jq -r '.manifest.media_type // empty' "$state_file")
  selected_manifest_size=$(jq -r '.manifest.size // 0' "$state_file")
}

# blobs ディレクトリに残っている blob 合計サイズを計算する。
local_blob_bytes() {
  local total=0
  local path size

  if [[ ! -d "$blobs_dir" ]]; then
    echo 0
    return
  fi

  while IFS= read -r -d '' path; do
    size=$(file_size "$path")
    total=$((total + size))
  done < <(find "$blobs_dir" -maxdepth 1 -type f -print0 2>/dev/null)

  echo "$total"
}

# 既に存在する完全な blob を state.json 側へ反映する。
mark_existing_blobs() {
  local digest size downloaded blob_path actual_size

  # 退避せずに残っている blob は state.json 側にも反映し、途中実行を継続しやすくする。
  while IFS=$'\t' read -r digest size downloaded; do
    blob_path="${blobs_dir}/$(digest_hex "$digest")"
    if [[ -f "$blob_path" ]]; then
      actual_size=$(file_size "$blob_path")
      if [[ "$actual_size" == "$size" ]]; then
        if [[ "$downloaded" != "true" ]]; then
          set_blob_downloaded "$digest"
        fi
      else
        warn "removing partial blob with unexpected size: $blob_path"
        rm -f "$blob_path"
      fi
    fi
  done < <(jq -r '.blobs[] | [.digest, (.size | tostring), (.downloaded | tostring)] | @tsv' "$state_file")
}

# 容量上限到達時の案内を表示して exit 20 で停止する。
pause_for_quota() {
  local current_bytes=$1
  local next_digest=${2:-}
  local next_size=${3:-}

  # ここでは自動退避せず止まるだけにして、実運用ではユーザが別媒体へ逃がせるようにする。
  echo
  printf "\033[33mALERT\033[0m: local blob usage reached the configured limit." >&2
  echo "  current: $(bytes_to_human "$current_bytes")" >&2
  echo "  limit:   $(bytes_to_human "$part_size_bytes")" >&2
  if [[ -n "$next_digest" ]]; then
    echo "  next:    $next_digest ($(bytes_to_human "$next_size"))" >&2
  fi
  echo >&2
  echo "Move the files under ${blobs_dir} to your temporary storage, keep state.json and manifest.json in place, then rerun the same command." >&2
  exit 20
}

# 単一 blob を取得し、サイズと digest を検証して配置する。
download_blob() {
  local digest=$1
  local expected_size=$2
  local role=$3
  local blob_path tmp_path actual_size actual_digest

  blob_path="${blobs_dir}/$(digest_hex "$digest")"
  tmp_path="${blob_path}.partial.$$"

  rm -f "$tmp_path"

  log "Downloading ${role} ${digest} ($(bytes_to_human "$expected_size"))"
  registry_get "https://${registry_api_host}/v2/${repository}/blobs/${digest}" "" "$tmp_path"
  rm -f "$last_response_headers"
  last_response_headers=""

  # 再開前提でも blob 単位では完全性を保証したいので、size と sha256 を必ず検証する。
  actual_size=$(file_size "$tmp_path")
  [[ "$actual_size" == "$expected_size" ]] || {
    rm -f "$tmp_path"
    die "downloaded blob size does not match manifest metadata: $digest (expected ${expected_size}, got ${actual_size})"
  }

  actual_digest=$(sha256sum "$tmp_path" | awk '{print $1}')
  [[ "$actual_digest" == "$(digest_hex "$digest")" ]] || {
    rm -f "$tmp_path"
    die "downloaded blob digest does not match: $digest"
  }

  mv "$tmp_path" "$blob_path"
}

# ここから下は「1回の実行フロー」本体。
# 1) 引数正規化 2) state 準備 3) 未取得 blob を順に取得、の順で進める。
parse_platform "$platform"
parse_image_ref "$image_ref"
part_size_bytes=$(gb_to_bytes "$part_size_gb") || die "--part-size-gb must be a positive number"
image_key=$(safe_name "$canonical_image_ref")
image_dir="${out_root}/${image_key}"
state_file="${image_dir}/state.json"
manifest_file="${image_dir}/manifest.json"
blobs_dir="${image_dir}/blobs/sha256"

mkdir -p "$blobs_dir"
refresh_manifest_and_state
mark_existing_blobs

if jq -e '.complete == true' "$state_file" >/dev/null 2>&1; then
  log "Complete"
  exit 0
fi

# part-size は「現在ローカルに残っている blob 合計」で判定する。
current_bytes=$(local_blob_bytes)
log "Local blob usage: $(bytes_to_human "$current_bytes") / $(bytes_to_human "$part_size_bytes")"

while IFS=$'\t' read -r digest size role downloaded; do
  [[ "$downloaded" == "true" ]] && continue

  # 次の blob を置くと上限超過する場合は、exit 20 で意図的に停止する。
  # 利用者は blob を退避して同じコマンドを再実行すれば続きから再開できる。

  if (( current_bytes > 0 && current_bytes + size > part_size_bytes )); then
    pause_for_quota "$current_bytes" "$digest" "$size"
  fi

  if (( current_bytes == 0 && size > part_size_bytes )); then
    die "blob ${digest} ($(bytes_to_human "$size")) exceeds the configured limit ($(bytes_to_human "$part_size_bytes")). Increase --part-size-gb."
  fi

  download_blob "$digest" "$size" "$role"
  set_blob_downloaded "$digest"
  current_bytes=$((current_bytes + size))

  done_count=$(jq -r '[.blobs[] | select(.downloaded == true)] | length' "$state_file")
  total_count=$(jq -r '.blobs | length' "$state_file")
  log "Downloaded ${done_count}/${total_count} blobs"

  if jq -e '.complete == true' "$state_file" >/dev/null 2>&1; then
    log "Complete"
    exit 0
  fi

  if (( current_bytes >= part_size_bytes )); then
    pause_for_quota "$current_bytes"
  fi
done < <(jq -r '.blobs[] | [.digest, (.size | tostring), .role, (.downloaded | tostring)] | @tsv' "$state_file")

if jq -e '.complete == true' "$state_file" >/dev/null 2>&1; then
  log "Complete"
  exit 0
fi

die "download finished unexpectedly without completing state.json"
