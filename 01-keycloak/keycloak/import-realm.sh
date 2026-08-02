#!/bin/sh
set -eu

# JSON文字列内へ埋め込む値をescapeする。
# 引数:
#   $1: JSON文字列として扱う生値。
# 戻り値:
#   backslashとdouble quoteをescapeした文字列を標準出力へ返す。
escape_json_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# sedのreplacementとして安全に渡せるようにescapeする。
# 引数:
#   $1: sed replacementへ渡す値。
# 戻り値:
#   区切り文字、ampersand、backslashをescapeした文字列を標準出力へ返す。
escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# JSON文字列用escapeとsed replacement用escapeを連続して適用する。
# 引数:
#   $1: JSON templateへ埋め込む生値。
# 戻り値:
#   JSON templateのsed置換に使える文字列を標準出力へ返す。
escape_json_sed_replacement() {
  escape_sed_replacement "$(escape_json_string "$1")"
}

realm_name="${STACK_NAME:-inferlab}"
open_webui_http_host_port="${OPEN_WEBUI_HTTP_HOST_PORT:-32000}"
dify_http_host_port="${DIFY_HTTP_HOST_PORT:-32100}"
nextcloud_http_host_port="${NEXTCLOUD_HTTP_HOST_PORT:-33000}"
bookstack_host_port="${BOOKSTACK_HOST_PORT:-33100}"
kaneo_http_host_port="${KANEO_HTTP_HOST_PORT:-33200}"
zulip_https_host_port="${ZULIP_HTTPS_HOST_PORT:-33300}"
gitea_http_host_port="${GITEA_HTTP_HOST_PORT:-33400}"
leantime_http_host_port="${LEANTIME_HTTP_HOST_PORT:-33900}"
grafana_http_host_port="${GRAFANA_HTTP_HOST_PORT:-35000}"
langfuse_http_host_port="${LANGFUSE_HTTP_HOST_PORT:-35100}"
keycloak_realm_admin_password="${KEYCLOAK_REALM_ADMIN_PASSWORD:-admin}"
keycloak_realm_admin_password_escaped="$(escape_json_sed_replacement "${keycloak_realm_admin_password}")"
nextcloud_oidc_client_secret="${NEXTCLOUD_OIDC_CLIENT_SECRET:-sk-nextcloud-oidc-client-secret-key}"
open_webui_oidc_client_secret="${OPEN_WEBUI_OIDC_CLIENT_SECRET:-open-webui-oauth-client-secret-key}"
dify_oidc_client_secret="${DIFY_OIDC_CLIENT_SECRET:-sk-dify-oidc-client-secret-key}"
langfuse_oidc_client_secret="${LANGFUSE_OIDC_CLIENT_SECRET:-sk-langfuse-oidc-client-secret-key}"
leantime_oidc_client_secret="${LEANTIME_OIDC_CLIENT_SECRET:-sk-leantime-oidc-client-secret-key}"
bookstack_oidc_client_secret="${BOOKSTACK_OIDC_CLIENT_SECRET:-sk-bookstack-oidc-client-secret-key}"
grafana_oidc_client_secret="${GRAFANA_OIDC_CLIENT_SECRET:-sk-grafana-oidc-client-secret-key}"
kaneo_oidc_client_secret="${KANEO_OIDC_CLIENT_SECRET:-sk-kaneo-oidc-client-secret-key}"
zulip_oidc_client_secret="${ZULIP_OIDC_CLIENT_SECRET:-sk-zulip-oidc-client-secret-key}"
gitea_oidc_client_secret="${GITEA_OIDC_CLIENT_SECRET:-sk-gitea-oidc-client-secret-key}"
nextcloud_oidc_client_secret_escaped="$(escape_json_sed_replacement "${nextcloud_oidc_client_secret}")"
open_webui_oidc_client_secret_escaped="$(escape_json_sed_replacement "${open_webui_oidc_client_secret}")"
dify_oidc_client_secret_escaped="$(escape_json_sed_replacement "${dify_oidc_client_secret}")"
langfuse_oidc_client_secret_escaped="$(escape_json_sed_replacement "${langfuse_oidc_client_secret}")"
leantime_oidc_client_secret_escaped="$(escape_json_sed_replacement "${leantime_oidc_client_secret}")"
bookstack_oidc_client_secret_escaped="$(escape_json_sed_replacement "${bookstack_oidc_client_secret}")"
grafana_oidc_client_secret_escaped="$(escape_json_sed_replacement "${grafana_oidc_client_secret}")"
kaneo_oidc_client_secret_escaped="$(escape_json_sed_replacement "${kaneo_oidc_client_secret}")"
zulip_oidc_client_secret_escaped="$(escape_json_sed_replacement "${zulip_oidc_client_secret}")"
gitea_oidc_client_secret_escaped="$(escape_json_sed_replacement "${gitea_oidc_client_secret}")"

mkdir -p /opt/keycloak/data/import

# 指定したテンプレートを環境変数で展開して出力する。
# 引数:
#   $1: 入力テンプレートのパス。
#   $2: 出力先のパス。
# 戻り値:
#   sedが成功した場合は0、失敗した場合は非0を返す。
render_template() {
  sed \
  -e "s|\${PUBLIC_HOST}|${PUBLIC_HOST}|g" \
  -e "s|\${STACK_NAME:-inferlab}|${realm_name}|g" \
  -e "s|\${OPEN_WEBUI_HTTP_HOST_PORT:-32000}|${open_webui_http_host_port}|g" \
  -e "s|\${DIFY_HTTP_HOST_PORT:-32100}|${dify_http_host_port}|g" \
  -e "s|\${NEXTCLOUD_HTTP_HOST_PORT:-33000}|${nextcloud_http_host_port}|g" \
  -e "s|\${BOOKSTACK_HOST_PORT:-33100}|${bookstack_host_port}|g" \
  -e "s|\${KANEO_HTTP_HOST_PORT:-33200}|${kaneo_http_host_port}|g" \
  -e "s|\${ZULIP_HTTPS_HOST_PORT:-33300}|${zulip_https_host_port}|g" \
  -e "s|\${GITEA_HTTP_HOST_PORT:-33400}|${gitea_http_host_port}|g" \
  -e "s|\${LEANTIME_HTTP_HOST_PORT:-33900}|${leantime_http_host_port}|g" \
  -e "s|\${GRAFANA_HTTP_HOST_PORT:-35000}|${grafana_http_host_port}|g" \
  -e "s|\${LANGFUSE_HTTP_HOST_PORT:-35100}|${langfuse_http_host_port}|g" \
  -e "s|\${KEYCLOAK_REALM_ADMIN_PASSWORD:-admin}|${keycloak_realm_admin_password_escaped}|g" \
  -e "s|\${NEXTCLOUD_OIDC_CLIENT_SECRET:-sk-nextcloud-oidc-client-secret-key}|${nextcloud_oidc_client_secret_escaped}|g" \
  -e "s|\${OPEN_WEBUI_OIDC_CLIENT_SECRET:-open-webui-oauth-client-secret-key}|${open_webui_oidc_client_secret_escaped}|g" \
  -e "s|\${DIFY_OIDC_CLIENT_SECRET:-sk-dify-oidc-client-secret-key}|${dify_oidc_client_secret_escaped}|g" \
  -e "s|\${LANGFUSE_OIDC_CLIENT_SECRET:-sk-langfuse-oidc-client-secret-key}|${langfuse_oidc_client_secret_escaped}|g" \
  -e "s|\${LEANTIME_OIDC_CLIENT_SECRET:-sk-leantime-oidc-client-secret-key}|${leantime_oidc_client_secret_escaped}|g" \
  -e "s|\${BOOKSTACK_OIDC_CLIENT_SECRET:-sk-bookstack-oidc-client-secret-key}|${bookstack_oidc_client_secret_escaped}|g" \
  -e "s|\${GRAFANA_OIDC_CLIENT_SECRET:-sk-grafana-oidc-client-secret-key}|${grafana_oidc_client_secret_escaped}|g" \
  -e "s|\${KANEO_OIDC_CLIENT_SECRET:-sk-kaneo-oidc-client-secret-key}|${kaneo_oidc_client_secret_escaped}|g" \
  -e "s|\${ZULIP_OIDC_CLIENT_SECRET:-sk-zulip-oidc-client-secret-key}|${zulip_oidc_client_secret_escaped}|g" \
  -e "s|\${GITEA_OIDC_CLIENT_SECRET:-sk-gitea-oidc-client-secret-key}|${gitea_oidc_client_secret_escaped}|g" \
  "$1" > "$2"
}

# Keycloak本体processが落ちていないことを確認する。
# 引数:
#   なし。
# 戻り値:
#   processが生存している場合は0、終了済みの場合はwait結果を返す。
ensure_keycloak_process_alive() {
  if ! kill -0 "${keycloak_pid}" 2>/dev/null; then
    wait "${keycloak_pid}"
  fi
}

render_template \
  /opt/keycloak/data/import-template/inferlab-realm.json \
  "/opt/keycloak/data/import/${realm_name}-realm.json"
render_template \
  /opt/keycloak/data/import-template/client-sync.json \
  "/tmp/${realm_name}-client-sync.json"

/opt/keycloak/bin/kc.sh start --import-realm &
keycloak_pid="$!"

trap 'kill "${keycloak_pid}" 2>/dev/null || true' INT TERM EXIT

for _ in $(seq 1 60); do
  if timeout 3 sh -c 'exec 3<>/dev/tcp/127.0.0.1/8080'; then
    break
  fi
  ensure_keycloak_process_alive
  sleep 2
done

authenticated=0
for _ in $(seq 1 60); do
  if /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://127.0.0.1:8080 \
    --realm master \
    --user "${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}" \
    --password "${KC_BOOTSTRAP_ADMIN_PASSWORD:-admin}" >/dev/null 2>&1; then
    authenticated=1
    break
  fi
  ensure_keycloak_process_alive
  sleep 2
done

if [ "${authenticated}" != "1" ]; then
  echo "Keycloak admin API authentication timed out." >&2
  exit 1
fi

synced=0
for _ in $(seq 1 60); do
  if /opt/keycloak/bin/kcadm.sh create partialImport \
    -r "${realm_name}" \
    -f "/tmp/${realm_name}-client-sync.json" >/dev/null 2>&1; then
    synced=1
    break
  fi
  ensure_keycloak_process_alive
  sleep 2
done

if [ "${synced}" != "1" ]; then
  echo "Keycloak OIDC client sync timed out." >&2
  exit 1
fi

trap - INT TERM EXIT
wait "${keycloak_pid}"
