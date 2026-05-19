# https://github.com/docling-project/docling-serve/blob/main/Containerfile
# https://quay.io/repository/docling-project/docling-serve
ARG BASE_TAG=latest
FROM quay.io/docling-project/docling-serve:${BASE_TAG}

USER root

# 日本語 Tesseract 言語パックを追加.
# ※ tesseract-langpack-jpn に含まれるフォントで十分なはずなので、追加でフォントをインストールしない.
RUN dnf install -y --best --nodocs --setopt=install_weak_deps=False \
    tesseract-langpack-jpn \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && fc-cache -f -v
# google-noto-sans-cjk-jp-fonts google-noto-serif-cjk-ttc-fonts

# tessdata_best (高精度モデル) で jpn / jpn_vert / eng を上書き。
ENV TESSDATA_PREFIX=/usr/share/tesseract/tessdata/
RUN test -d "${TESSDATA_PREFIX%/}" && \
    echo "tessdata dir: ${TESSDATA_PREFIX%/}" && \
    curl -fsSL -o "${TESSDATA_PREFIX%/}/jpn.traineddata" \
    https://github.com/tesseract-ocr/tessdata_best/raw/main/jpn.traineddata && \
    curl -fsSL -o "${TESSDATA_PREFIX%/}/jpn_vert.traineddata" \
    https://github.com/tesseract-ocr/tessdata_best/raw/main/jpn_vert.traineddata && \
    curl -fsSL -o "${TESSDATA_PREFIX%/}/eng.traineddata" \
    https://github.com/tesseract-ocr/tessdata_best/raw/main/eng.traineddata
RUN tesseract --list-langs 2>&1 | grep -E "jpn|jpn_vert|eng" || echo "WARNING: language check failed"

# docling-serve が参照するモデル格納先を明示.
ENV DOCLING_SERVE_ARTIFACTS_PATH=/opt/app-root/src/.cache/docling/models
ENV HF_HOME=/opt/app-root/src/.cache/huggingface
ENV TRANSFORMERS_CACHE=/opt/app-root/src/.cache/huggingface
RUN mkdir -p "${DOCLING_SERVE_ARTIFACTS_PATH}" "${HF_HOME}" && \
    chown -R 1001:0 /opt/app-root/src/.cache && \
    chmod -R g=u /opt/app-root/src/.cache

# Docling MCP を LAN IP 経由で使えるように DNS rebinding protection を無効化.
RUN python3 - <<'PY'
from pathlib import Path
import docling_mcp.shared

path = Path(docling_mcp.shared.__file__)
text = path.read_text()

import_line = "from mcp.server.transport_security import TransportSecuritySettings\n"
old_mcp = 'mcp = FastMCP("docling")'
new_mcp = '''mcp = FastMCP(
    "docling",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=False,
    ),
)'''

if import_line not in text:
    text = text.replace(
        "from mcp.server.fastmcp import FastMCP\n",
        "from mcp.server.fastmcp import FastMCP\n"
        "from mcp.server.transport_security import TransportSecuritySettings\n",
    )

if old_mcp in text:
    text = text.replace(old_mcp, new_mcp)
elif new_mcp in text:
    pass
else:
    raise SystemExit(f"Expected FastMCP declaration not found in {path}")

path.write_text(text)
print(f"Patched {path}")
PY

# docling-serve が起動時に使う標準モデル・ツールをビルド時に取得.
# ※ rapidocr easyocrは使う予定がないので、ダウンロード対象から外す.
USER 1001
ENV DOCLING_SERVE_LOAD_MODELS_AT_BOOT=false
# ARG MODELS_LIST="layout tableformer picture_classifier rapidocr easyocr smolvlm"
ARG MODELS_LIST="layout tableformer picture_classifier smolvlm"
RUN echo "Downloading models..." && \
    HF_HUB_DOWNLOAD_TIMEOUT="90" \
    HF_HUB_ETAG_TIMEOUT="90" \
    docling-tools models download -o "${DOCLING_SERVE_ARTIFACTS_PATH}" ${MODELS_LIST} && \
    chown -R 1001:0 ${DOCLING_SERVE_ARTIFACTS_PATH} && \
    chmod -R g=u ${DOCLING_SERVE_ARTIFACTS_PATH} && \
    test -d "${DOCLING_SERVE_ARTIFACTS_PATH}/docling-project--docling-layout-heron"

# HuggingFace Hub のオフラインモードを有効化.
ENV HF_HUB_OFFLINE=1
ENV TRANSFORMERS_OFFLINE=1

# WORKDIR /opt/app-root/src
# EXPOSE 5001
# CMD ["docling-serve", "run"]
