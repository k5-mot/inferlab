#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

if ! php /var/www/html/occ list user_oidc >/dev/null 2>&1; then
  exit 0
fi

: "${NEXTCLOUD_OIDC_PROVIDER_ID:=keycloak}"
: "${NEXTCLOUD_OIDC_CLIENT_ID:=nextcloud}"
: "${NEXTCLOUD_OIDC_CLIENT_SECRET:=sk-nextcloud-oidc-client-secret-key}"
: "${NEXTCLOUD_OIDC_DISCOVERY_URL:=}"
: "${NEXTCLOUD_OIDC_END_SESSION_ENDPOINT:=}"
: "${NEXTCLOUD_OIDC_POST_LOGOUT_URI:=}"
: "${NEXTCLOUD_OIDC_SCOPE:=openid profile email}"
: "${NEXTCLOUD_OIDC_MAPPING_UID:=preferred_username}"
: "${NEXTCLOUD_OIDC_MAPPING_DISPLAY_NAME:=name}"
: "${NEXTCLOUD_OIDC_MAPPING_EMAIL:=email}"
: "${NEXTCLOUD_OIDC_MAPPING_GROUPS:=groups}"
: "${NEXTCLOUD_OIDC_UNIQUE_UID:=0}"
: "${NEXTCLOUD_OIDC_GROUP_PROVISIONING:=1}"

if [ -z "${NEXTCLOUD_OIDC_DISCOVERY_URL}" ] ||
  [ -z "${NEXTCLOUD_OIDC_END_SESSION_ENDPOINT}" ] ||
  [ -z "${NEXTCLOUD_OIDC_POST_LOGOUT_URI}" ]; then
  exit 0
fi

# Nextcloud側のログアウト時にKeycloakのSSOセッションも閉じる。
php /var/www/html/occ user_oidc:provider "${NEXTCLOUD_OIDC_PROVIDER_ID}" \
  --clientid="${NEXTCLOUD_OIDC_CLIENT_ID}" \
  --clientsecret="${NEXTCLOUD_OIDC_CLIENT_SECRET}" \
  --discoveryuri="${NEXTCLOUD_OIDC_DISCOVERY_URL}" \
  --endsessionendpointuri="${NEXTCLOUD_OIDC_END_SESSION_ENDPOINT}" \
  --postlogouturi="${NEXTCLOUD_OIDC_POST_LOGOUT_URI}" \
  --scope="${NEXTCLOUD_OIDC_SCOPE}" \
  --send-id-token-hint=1 \
  --mapping-uid="${NEXTCLOUD_OIDC_MAPPING_UID}" \
  --mapping-display-name="${NEXTCLOUD_OIDC_MAPPING_DISPLAY_NAME}" \
  --mapping-email="${NEXTCLOUD_OIDC_MAPPING_EMAIL}" \
  --mapping-groups="${NEXTCLOUD_OIDC_MAPPING_GROUPS}" \
  --unique-uid="${NEXTCLOUD_OIDC_UNIQUE_UID}" \
  --group-provisioning="${NEXTCLOUD_OIDC_GROUP_PROVISIONING}"
