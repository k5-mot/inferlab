#!/bin/sh

set -eu

VERSION="${USER_OIDC_VERSION:-8.10.1}"
DEST_DIR="${NEXTCLOUD_USER_OIDC_DEST_DIR:-/srv/30-nextcloud/apps}"
DEST_FILE="${DEST_DIR}/user_oidc-v${VERSION}.tar.gz"
URL="https://github.com/nextcloud-releases/user_oidc/releases/download/v${VERSION}/user_oidc-v${VERSION}.tar.gz"

mkdir -p "${DEST_DIR}"

echo "Downloading user_oidc v${VERSION}..."
curl -fL "${URL}" -o "${DEST_FILE}"

echo "Downloaded: ${DEST_FILE}"
