#!/bin/sh
set -eu

# GiteaのOAuth sourceは環境変数だけでは更新されないため、起動後にCLIで冪等同期する。
auth_id="$(gitea admin auth list --config /data/gitea/conf/app.ini | awk '$2 == "keycloak" { print $1; exit }')"

auth_action="add-oauth"
auth_id_option=""
if [ -n "${auth_id}" ]; then
  auth_action="update-oauth"
  auth_id_option="--id ${auth_id}"
fi

# shellcheck disable=SC2086
gitea admin auth "${auth_action}" \
  --config /data/gitea/conf/app.ini \
  ${auth_id_option} \
  --name keycloak \
  --provider openidConnect \
  --key gitea \
  --secret "${GITEA_OIDC_CLIENT_SECRET}" \
  --auto-discover-url "${GITEA_OIDC_DISCOVERY_URL}" \
  --scopes openid \
  --scopes email \
  --scopes profile \
  --group-claim-name groups
