#!/bin/sh
set -eu

# Nextcloud Docker 公式イメージの起動前 hook。
# インストール済み環境でも毎回起動時に実行されるため、
# user_oidc の HTTP 許可設定と、LAN 内 Keycloak への到達許可を維持できる。
# HTTPS で提供する場合は NEXTCLOUD_OIDC_ALLOW_INSECURE_HTTP=false にする。
if php occ status | grep -q "installed: true"; then
  php occ config:app:set --type=boolean --value="${NEXTCLOUD_OIDC_ALLOW_INSECURE_HTTP:-true}" user_oidc allow_insecure_http
  php occ config:system:set --type=boolean --value="${NEXTCLOUD_ALLOW_LOCAL_REMOTE_SERVERS:-true}" allow_local_remote_servers
fi
