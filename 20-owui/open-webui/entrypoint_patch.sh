#!/usr/bin/env bash
set -euo pipefail

# 大容量PDFをDoclingへ一括送信しないよう、Open WebUIのloaderへ分割処理を追加する。
python /run/scripts/patch-docling-pdf-batches.py

# Open WebUI の DoclingLoader が multipart form として送るため、ネストした値は JSON 文字列に畳む。
unset DOCLING_PARAMS
DOCLING_PARAMS="$(python /run/scripts/export_docling_params.py /run/config/docling_params.json)"
export DOCLING_PARAMS

exec bash start.sh
