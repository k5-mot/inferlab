#!/bin/sh
set -eu

realm_name="${STACK_NAME:-inferlab}"
nextcloud_oidc_client_secret="${NEXTCLOUD_OIDC_CLIENT_SECRET:-sk-nextcloud-oidc-client-secret-key}"
langfuse_oidc_client_secret="${LANGFUSE_OIDC_CLIENT_SECRET:-sk-langfuse-oidc-client-secret-key}"

mkdir -p /opt/keycloak/data/import
sed \
  -e "s|\${PUBLIC_HOST}|${PUBLIC_HOST}|g" \
  -e "s|\${STACK_NAME:-inferlab}|${realm_name}|g" \
  -e "s|\${NEXTCLOUD_OIDC_CLIENT_SECRET:-sk-nextcloud-oidc-client-secret-key}|${nextcloud_oidc_client_secret}|g" \
  -e "s|\${LANGFUSE_OIDC_CLIENT_SECRET:-sk-langfuse-oidc-client-secret-key}|${langfuse_oidc_client_secret}|g" \
  /opt/keycloak/data/import-template/inferlab-realm.json \
  > "/opt/keycloak/data/import/${realm_name}-realm.json"

exec /opt/keycloak/bin/kc.sh start --import-realm
