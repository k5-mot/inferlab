#!/bin/sh
set -eu

realm_name="${STACK_NAME:-inferlab}"
grafana_http_host_port="${GRAFANA_HTTP_HOST_PORT:-35000}"
keycloak_realm_admin_password="${KEYCLOAK_REALM_ADMIN_PASSWORD:-admin}"
keycloak_realm_admin_password_json_escaped="$(printf '%s' "${keycloak_realm_admin_password}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
keycloak_realm_admin_password_escaped="$(printf '%s' "${keycloak_realm_admin_password_json_escaped}" | sed 's/[&|\\]/\\&/g')"
nextcloud_oidc_client_secret="${NEXTCLOUD_OIDC_CLIENT_SECRET:-sk-nextcloud-oidc-client-secret-key}"
open_webui_oidc_client_secret="${OPEN_WEBUI_OIDC_CLIENT_SECRET:-open-webui-oauth-client-secret-key}"
langfuse_oidc_client_secret="${LANGFUSE_OIDC_CLIENT_SECRET:-sk-langfuse-oidc-client-secret-key}"
leantime_oidc_client_secret="${LEANTIME_OIDC_CLIENT_SECRET:-sk-leantime-oidc-client-secret-key}"
bookstack_oidc_client_secret="${BOOKSTACK_OIDC_CLIENT_SECRET:-sk-bookstack-oidc-client-secret-key}"
grafana_oidc_client_secret="${GRAFANA_OIDC_CLIENT_SECRET:-sk-grafana-oidc-client-secret-key}"
zulip_oidc_client_secret="${ZULIP_OIDC_CLIENT_SECRET:-sk-zulip-oidc-client-secret-key}"

mkdir -p /opt/keycloak/data/import
sed \
  -e "s|\${PUBLIC_HOST}|${PUBLIC_HOST}|g" \
  -e "s|\${STACK_NAME:-inferlab}|${realm_name}|g" \
  -e "s|\${GRAFANA_HTTP_HOST_PORT:-35000}|${grafana_http_host_port}|g" \
  -e "s|\${KEYCLOAK_REALM_ADMIN_PASSWORD:-admin}|${keycloak_realm_admin_password_escaped}|g" \
  -e "s|\${NEXTCLOUD_OIDC_CLIENT_SECRET:-sk-nextcloud-oidc-client-secret-key}|${nextcloud_oidc_client_secret}|g" \
  -e "s|\${OPEN_WEBUI_OIDC_CLIENT_SECRET:-open-webui-oauth-client-secret-key}|${open_webui_oidc_client_secret}|g" \
  -e "s|\${LANGFUSE_OIDC_CLIENT_SECRET:-sk-langfuse-oidc-client-secret-key}|${langfuse_oidc_client_secret}|g" \
  -e "s|\${LEANTIME_OIDC_CLIENT_SECRET:-sk-leantime-oidc-client-secret-key}|${leantime_oidc_client_secret}|g" \
  -e "s|\${BOOKSTACK_OIDC_CLIENT_SECRET:-sk-bookstack-oidc-client-secret-key}|${bookstack_oidc_client_secret}|g" \
  -e "s|\${GRAFANA_OIDC_CLIENT_SECRET:-sk-grafana-oidc-client-secret-key}|${grafana_oidc_client_secret}|g" \
  -e "s|\${ZULIP_OIDC_CLIENT_SECRET:-sk-zulip-oidc-client-secret-key}|${zulip_oidc_client_secret}|g" \
  /opt/keycloak/data/import-template/inferlab-realm.json \
  > "/opt/keycloak/data/import/${realm_name}-realm.json"

exec /opt/keycloak/bin/kc.sh start --import-realm
