#!/bin/sh
set -eu

flag_file="/app/api/storage/.init_permissions"

# Dify API/workerはUID 1001でstorage volumeへ書き込むため、初回だけ所有者を合わせる。
# marker fileで再帰chownを避け、再起動時の待ち時間を増やさない。
if [ -f "${flag_file}" ]; then
  echo "Permissions already initialized. Exiting."
  exit 0
fi

echo "Initializing permissions for /app/api/storage"
chown -R 1001:1001 /app/api/storage
touch "${flag_file}"
echo "Permissions initialized. Exiting."
