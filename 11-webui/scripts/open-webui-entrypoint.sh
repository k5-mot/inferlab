#!/usr/bin/env bash
set -euo pipefail

# Open WebUI 本体の修正が取り込まれるまで、Channels の応答保存だけ起動時に補正する。
python /run/patches/open-webui-channel-stream-drain.py

# Open WebUI の DoclingLoader が multipart form として送るため、ネストした値は JSON 文字列に畳む。
export DOCLING_PARAMS="$(python /run/scripts/render-docling-params.py /run/config/docling_params.json)"

exec bash start.sh
