#!/bin/sh
set -eu

realm_name="${STACK_NAME:-inferlab}"

mkdir -p /opt/keycloak/data/import
sed \
  -e "s|\${PUBLIC_HOST}|${PUBLIC_HOST}|g" \
  -e "s|\${STACK_NAME:-inferlab}|${realm_name}|g" \
  /opt/keycloak/data/import-template/inferlab-realm.json \
  > "/opt/keycloak/data/import/${realm_name}-realm.json"

exec /opt/keycloak/bin/kc.sh start --import-realm
