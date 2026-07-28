#!/usr/bin/env bash
set -euo pipefail

# Open WebUI の DoclingLoader が multipart form として送るため、ネストした値は JSON 文字列に畳む。
unset DOCLING_PARAMS
export DOCLING_PARAMS="$(python /run/scripts/export_docling_params.py /run/config/docling_params.json)"

exec bash start.sh
