#!/usr/bin/env sh
set -eu

cert_dir="$(CDPATH= cd -- "$(dirname -- "$0")/certs" && pwd)"
public_host="${PUBLIC_HOST:-localhost}"

# `PUBLIC_HOST`がIPの場合はIP SAN、host名の場合はDNS SANにし、browser検証の警告を減らす。
case "$public_host" in
  *[!0-9.]*)
    subject_alt_name="DNS:${public_host},DNS:localhost"
    ;;
  *)
    subject_alt_name="IP:${public_host},DNS:localhost"
    ;;
esac

mkdir -p "$cert_dir"

# ZulipのOIDC連携に使うLAN用の自己署名証明書を生成する。
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

# private keyはownerのみ、certificateはcontainerから読めるように権限を分ける。
chmod 600 "$cert_dir/keycloak.key"
chmod 644 "$cert_dir/keycloak.crt"
