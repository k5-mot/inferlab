#!/usr/bin/env sh
set -eu

cert_dir="$(CDPATH= cd -- "$(dirname -- "$0")/certs" && pwd)"
public_host="${PUBLIC_HOST:-localhost}"

case "$public_host" in
  *[!0-9.]*)
    subject_alt_name="DNS:${public_host},DNS:localhost"
    ;;
  *)
    subject_alt_name="IP:${public_host},DNS:localhost"
    ;;
esac

mkdir -p "$cert_dir"

# BookStackのOIDC連携はHTTPS issuerを必須にするため、LAN用の自己署名証明書を生成する。
openssl req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days "${KEYCLOAK_CERT_DAYS:-3650}" \
  -nodes \
  -keyout "$cert_dir/keycloak.key" \
  -out "$cert_dir/keycloak.crt" \
  -subj "/CN=${public_host}" \
  -addext "subjectAltName=${subject_alt_name}"

chmod 600 "$cert_dir/keycloak.key"
chmod 644 "$cert_dir/keycloak.crt"
