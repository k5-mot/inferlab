#!/usr/bin/with-contenv sh
set -eu

# BookStackのOIDC discoveryで、ローカルKeycloak HTTPSの自己署名証明書を信頼する。
if [ -f /usr/local/share/ca-certificates/keycloak.crt ]; then
  update-ca-certificates
fi
