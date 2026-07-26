#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

: "${NEXTCLOUD_OPENMETRICS_ALLOWED_CLIENTS:=127.0.0.0/16 ::1/128 172.16.0.0/12}"

# Docker内部networkからのPrometheus scrapeだけを許可する。
php /var/www/html/occ config:system:delete openmetrics_allowed_clients || true

index=0
for client in ${NEXTCLOUD_OPENMETRICS_ALLOWED_CLIENTS}; do
  php /var/www/html/occ config:system:set openmetrics_allowed_clients "${index}" --value="${client}"
  index=$((index + 1))
done
