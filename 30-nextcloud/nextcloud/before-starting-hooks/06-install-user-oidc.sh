#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

version=8.10.1
expected_sha256=49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd
source_archive="/srv/30-nextcloud/apps/user_oidc-v${version}.tar.gz"

app_dir=/var/www/html/custom_apps/user_oidc
archive=/tmp/user_oidc.tar.gz
extract_dir=/tmp/user_oidc-extract

if php /var/www/html/occ list user_oidc >/dev/null 2>&1; then
  exit 0
fi

# Nextcloud本体imageにOIDC appを焼き込まず、volume初期化時だけcustom_appsへ配置する。
if [ ! -f "${source_archive}" ]; then
  echo "Nextcloud OIDC app archiveが見つかりません: ${source_archive}" >&2
  exit 1
fi

rm -rf "${archive}" "${extract_dir}"
mkdir -p "${extract_dir}"

# 外部取得資材は起動前に/srvへ集め、起動時はbind mountしたarchiveだけを使う。
cp "${source_archive}" "${archive}"
echo "${expected_sha256}  ${archive}" | sha256sum -c -

tar -xzf "${archive}" -C "${extract_dir}"
rm -rf "${app_dir}"
mv "${extract_dir}/user_oidc" "${app_dir}"
chown -R www-data:www-data "${app_dir}"
rm -rf "${archive}" "${extract_dir}"

php /var/www/html/occ app:enable user_oidc
