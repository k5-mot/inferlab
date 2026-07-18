#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

su -s /bin/sh www-data -c "php /var/www/html/occ config:system:set updatechecker --type boolean --value false"
su -s /bin/sh www-data -c "php /var/www/html/occ config:system:set has_internet_connection --type boolean --value false"
su -s /bin/sh www-data -c "php /var/www/html/occ app:disable survey_client" || true
su -s /bin/sh www-data -c "php /var/www/html/occ app:disable recommendations" || true
