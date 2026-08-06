#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${SCRIPT_DIR}/packages"

LANGFUSE_VERSION="${LANGFUSE_VERSION:-4.14.1}"

# Docker 実行環境に合わせる
PIP_PLATFORM="${PIP_PLATFORM:-manylinux_2_17_x86_64}"
PIP_PYTHON_VERSION="${PIP_PYTHON_VERSION:-3.11}"
PIP_IMPLEMENTATION="${PIP_IMPLEMENTATION:-cp}"

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}"

python -m pip download \
    --dest "${PACKAGE_DIR}" \
    --platform "${PIP_PLATFORM}" \
    --python-version "${PIP_PYTHON_VERSION}" \
    --implementation "${PIP_IMPLEMENTATION}" \
    --only-binary=:all: \
    "langfuse==${LANGFUSE_VERSION}"
