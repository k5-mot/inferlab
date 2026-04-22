#!/usr/bin/env bash
set -euo pipefail

# Windows 側で作った *_PartN.tar を GPU サーバ側で結合し、
# 既定ではそのまま docker load するための復元スクリプト。
usage() {
  cat <<'EOF'
Usage:
  ./merge.sh [--no-load] [--sha256] [--force] PARTS_DIR FILE_BASE [OUTPUT_TAR]

Examples:
  ./merge.sh /data/parts vllm_vllm-openai_v0.19.1
  ./merge.sh --sha256 /data/parts vllm_vllm-openai_v0.19.1 /data/vllm_vllm-openai_v0.19.1_FullPart.tar

Options:
  --no-load   Only merge parts; do not run docker load.
  --sha256    Print sha256sum of the merged tar.
  --force     Overwrite OUTPUT_TAR if it already exists.
  -h, --help  Show this help.

Environment:
  TINYLOADER_SKIP_DOCKER_LOAD=1  Same effect as --no-load.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# テストや事前確認では --no-load を使い、Docker への取り込みを避けられるようにする。
no_load=false
print_sha256=false
force=false

# オプションは先頭だけで処理し、残りを PARTS_DIR / FILE_BASE / OUTPUT_TAR として扱う。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-load)
      no_load=true
      shift
      ;;
    --sha256)
      print_sha256=true
      shift
      ;;
    --force)
      force=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -ge 2 && $# -le 3 ]] || {
  usage >&2
  exit 2
}

parts_dir=$1
file_base=$2
output_tar=${3:-"$parts_dir/${file_base}_FullPart.tar"}

# sort -V は Part2 と Part10 を自然順で並べるために必須。
[[ -d "$parts_dir" ]] || die "parts directory not found: $parts_dir"
command -v sort >/dev/null 2>&1 || die "sort is required"
sort --version >/dev/null 2>&1 || die "GNU sort is required for sort -V"

# 指定された FILE_BASE に完全一致する Part だけを拾う。
# 似た名前の別イメージの Part が混ざっても、ここで除外する。
mapfile -t parts < <(
  find "$parts_dir" -maxdepth 1 -type f -name '*_Part*.tar' -print |
    while IFS= read -r path; do
      name=$(basename "$path")
      prefix="${file_base}_Part"
      if [[ "$name" == "$prefix"*".tar" ]]; then
        part_number=${name#"$prefix"}
        part_number=${part_number%.tar}
        if [[ "$part_number" =~ ^[0-9]+$ ]]; then
          printf '%s\n' "$path"
        fi
      fi
    done |
    sort -V
)

[[ ${#parts[@]} -gt 0 ]] || die "no part files found: ${file_base}_Part*.tar in $parts_dir"

# Part1 から連番になっているかを確認する。
# 欠損したまま cat すると docker load 時に壊れ方が分かりにくいため、ここで止める。
expected=1
for part in "${parts[@]}"; do
  name=$(basename "$part")
  prefix="${file_base}_Part"
  part_number=${name#"$prefix"}
  part_number=${part_number%.tar}

  [[ "$part_number" =~ ^[0-9]+$ ]] || die "invalid part file name: $name"
  [[ "$part_number" -eq "$expected" ]] || die "missing or out-of-order part: expected Part$expected, found Part$part_number"
  [[ -s "$part" ]] || die "part file is empty: $part"

  expected=$((expected + 1))
done

# 既存 tar を誤って上書きしない。上書きしたい場合だけ --force を明示する。
if [[ -e "$output_tar" && "$force" != true ]]; then
  die "output tar already exists: $output_tar"
fi

output_dir=$(dirname "$output_tar")
[[ -d "$output_dir" ]] || die "output directory not found: $output_dir"

tmp_output="${output_tar}.tmp.$$"
cleanup() {
  rm -f "$tmp_output"
}
trap cleanup EXIT

# 結合中に失敗した場合に壊れた完成 tar を残さないよう、一時ファイルへ書く。
echo "Merging ${#parts[@]} part(s) into: $output_tar"
: > "$tmp_output"
for part in "${parts[@]}"; do
  echo "  + $(basename "$part")"
  cat "$part" >> "$tmp_output"
done

mv -f "$tmp_output" "$output_tar"
trap - EXIT

# 任意で sha256sum を出す。ファイルサーバ転送後の確認値として使える。
if [[ "$print_sha256" == true ]]; then
  sha256sum "$output_tar"
fi

# CI や Windows+WSL の検証では docker が無いことがあるため、結合だけで止められる。
if [[ "$no_load" == true || "${TINYLOADER_SKIP_DOCKER_LOAD:-0}" == "1" ]]; then
  echo "docker load skipped."
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker command not found. Re-run with --no-load to merge only."

# 本番 GPU サーバではここで Docker イメージとして取り込む。
echo "Loading image into Docker: $output_tar"
docker load -i "$output_tar"
