#!/bin/sh
set -eu

# Nextcloud Docker 公式イメージの初回インストール後 hook。
# 別の one-shot init サービスを増やさず、公式コンテナのライフサイクル内で
# user_oidc のインストールと Keycloak provider 登録を行う。
php occ app:install user_oidc || true
php occ app:enable user_oidc

php occ user_oidc:provider "${NEXTCLOUD_OIDC_PROVIDER_ID}" \
  --clientid="${NEXTCLOUD_OIDC_CLIENT_ID}" \
  --clientsecret="${NEXTCLOUD_OIDC_CLIENT_SECRET}" \
  --discoveryuri="${NEXTCLOUD_OIDC_DISCOVERY_URL}" \
  --scope="${NEXTCLOUD_OIDC_SCOPE}" \
  --mapping-uid="${NEXTCLOUD_OIDC_MAPPING_UID}" \
  --mapping-display-name="${NEXTCLOUD_OIDC_MAPPING_DISPLAY_NAME}" \
  --mapping-email="${NEXTCLOUD_OIDC_MAPPING_EMAIL}" \
  --mapping-groups="${NEXTCLOUD_OIDC_MAPPING_GROUPS}" \
  --unique-uid="${NEXTCLOUD_OIDC_UNIQUE_UID}" \
  --group-provisioning="${NEXTCLOUD_OIDC_GROUP_PROVISIONING}"

php occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends
php occ config:app:set --type=boolean --value="${NEXTCLOUD_OIDC_ALLOW_INSECURE_HTTP}" user_oidc allow_insecure_http
php occ config:system:set --type=boolean --value="${NEXTCLOUD_ALLOW_LOCAL_REMOTE_SERVERS}" allow_local_remote_servers
