#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

: "${NEXTCLOUD_TRUSTED_DOMAINS:=localhost 127.0.0.1 nextcloud}"

# 初期化済みvolumeでもcompose側の公開host設定をNextcloud実設定へ反映する。
php /var/www/html/occ config:system:delete trusted_domains || true

index=0
for domain in ${NEXTCLOUD_TRUSTED_DOMAINS}; do
  php /var/www/html/occ config:system:set trusted_domains "${index}" --value="${domain}"
  index=$((index + 1))
done
