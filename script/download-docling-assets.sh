#!/usr/bin/env bash
set -euo pipefail

output_directory="out"
tessdata_revision="e12c65a915945e4c28e237a9b52bc4a8f39a0cec"
tessdata_base_url="https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/${tessdata_revision}"
# model catalogの⭐を明示的なCLI IDへ固定し、--allによる対象外modelの混入を防ぐ。
# v1.30.0のOCR Auto warm-upはRapidOCRを選ぶため、rapidocrとTesseract traineddataの両方を取得する。
docling_models=(
  layout
  tableformer
  rapidocr
  picture_classifier
  granitedocling
  smolvlm
  code_formula
)
tessdata_assets=(
  "eng.traineddata|8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba"
  "jpn.traineddata|36bdf9ac823f5911e624c30d0553e890b8abc7c31a65b3ef14da943658c40b79"
  "jpn_vert.traineddata|1258be6eb2a9851f18043234ad18cca13ed32690bfff62b335c898bbea371548"
  "osd.traineddata|9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff"
  "script/Japanese.traineddata|c716f6a9d413b3c127f2f9defd9b6f4bba84eeb6c5bfd6feba7922d8025ddf2f"
  "script/Japanese_vert.traineddata|6eca729ad647326a2149e09cf0589d626f4e746863092e22f46841eae4574a49"
)

# usage:
# 用途: command line引数と既定保存先を表示する。
# 引数: なし。
# 戻り値: 標準出力へhelpを出力し、常に0を返す。
usage() {
  cat <<'EOF'
Usage: download-docling-assets.sh [--output-directory DIRECTORY] [--help]

Docling modelとTesseract traineddataを事前取得します。

Options:
  --output-directory DIRECTORY  srv/docling/を作成する出力先（default: out）
  --help                        helpを表示する
EOF
}

# require_command:
# 用途: 必要なcommandがPATH上で利用可能であることを確認する。
# 引数: $1に確認するcommand名を指定する。
# 戻り値: commandが存在すれば0、存在しなければerror messageを出力して1を返す。
require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command_name}" >&2
    return 1
  fi
}

# download_docling_models:
# 用途: Docling公式CLIで選択したmodelを保存先へ取得する。
# 引数: $1にmodel保存先directoryを指定する。
# 戻り値: download成功時は0、docling-tools失敗時はその終了codeを返す。
# 副作用: 保存先directoryのmodel fileを作成または更新する。
download_docling_models() {
  local model_directory="$1"

  mkdir -p "${model_directory}"
  docling-tools models download \
    --output-dir "${model_directory}" \
    "${docling_models[@]}"
}

# download_tessdata:
# 用途: Tesseract traineddataを取得し、SHA-256を検証する。
# 引数: $1に相対path、$2に期待SHA-256、$3に保存先base directoryを指定する。
# 戻り値: downloadと検証の成功時は0、失敗時は非0を返す。
# 副作用: 保存先のtraineddata fileを作成または上書きする。
download_tessdata() {
  local relative_path="$1"
  local expected_sha256="$2"
  local output_directory="$3"
  local output_path="${output_directory}/${relative_path}"

  mkdir -p "$(dirname "${output_path}")"
  printf 'Download Tesseract traineddata: %s\n' "${relative_path}"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --output "${output_path}" \
    "${tessdata_base_url}/${relative_path}"

  if ! printf '%s  %s\n' "${expected_sha256}" "${output_path}" | sha256sum --check --status; then
    printf 'Tesseract traineddataのchecksumが一致しません: %s\n' "${relative_path}" >&2
    return 1
  fi
}

# main:
# 用途: 引数を解析し、Docling modelとTesseract traineddataを事前取得する。
# 引数: command line引数をそのまま受け取る。
# 戻り値: 全資材の取得成功時は0、不正引数またはdownload失敗時は非0を返す。
# 副作用: 指定保存先配下へmodelとtraineddataを作成または更新する。
main() {
  while (($# > 0)); do
    case "$1" in
      --output-directory)
        if (($# < 2)); then
          printf '%s\n' '--output-directoryには値が必要です。' >&2
          return 2
        fi
        output_directory="$2"
        shift 2
        ;;
      --help)
        usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  require_command docling-tools
  require_command curl
  require_command sha256sum

  local docling_directory="${output_directory}/srv/docling"
  local tessdata_directory="${docling_directory}/tesseract"
  local asset
  local relative_path
  local expected_sha256

  download_docling_models "${docling_directory}"

  for asset in "${tessdata_assets[@]}"; do
    IFS='|' read -r relative_path expected_sha256 <<<"${asset}"
    download_tessdata "${relative_path}" "${expected_sha256}" "${tessdata_directory}"
  done

  printf 'Docling assets are ready: %s\n' "${docling_directory}"
}

main "$@"
