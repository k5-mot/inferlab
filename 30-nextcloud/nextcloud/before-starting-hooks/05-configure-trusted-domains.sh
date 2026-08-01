#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

: "${NEXTCLOUD_TRUSTED_DOMAINS:=localhost 127.0.0.1 nextcloud}"
: "${NEXTCLOUD_ALLOW_LOCAL_REMOTE_SERVERS:=false}"

# 初期化済みvolumeでもcompose側の公開host設定をNextcloud実設定へ反映する。
php /var/www/html/occ config:system:delete trusted_domains || true

index=0
for domain in ${NEXTCLOUD_TRUSTED_DOMAINS}; do
  php /var/www/html/occ config:system:set trusted_domains "${index}" --value="${domain}"
  index=$((index + 1))
done

# Docker host上のKeycloakなど、private addressの連携先へ到達できるようにする。
allow_local_remote_servers=false
case "${NEXTCLOUD_ALLOW_LOCAL_REMOTE_SERVERS}" in
  1 | true | TRUE | yes | YES | on | ON)
    allow_local_remote_servers=true
    ;;
esac
php /var/www/html/occ config:system:set allow_local_remote_servers --type boolean --value "${allow_local_remote_servers}"
