#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

: "${NEXTCLOUD_USER_OIDC_VERSION:=8.10.1}"
: "${NEXTCLOUD_USER_OIDC_SHA256:=49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd}"
: "${NEXTCLOUD_USER_OIDC_ARCHIVE:=/opt/inferlab/nextcloud-apps/user_oidc-v${NEXTCLOUD_USER_OIDC_VERSION}.tar.gz}"
: "${NEXTCLOUD_USER_OIDC_URL:=https://github.com/nextcloud-releases/user_oidc/releases/download/v${NEXTCLOUD_USER_OIDC_VERSION}/user_oidc-v${NEXTCLOUD_USER_OIDC_VERSION}.tar.gz}"

app_dir=/var/www/html/custom_apps/user_oidc
archive=/tmp/user_oidc.tar.gz
extract_dir=/tmp/user_oidc-extract

if php /var/www/html/occ list user_oidc >/dev/null 2>&1; then
  exit 0
fi

# Nextcloud本体imageにOIDC appを焼き込まず、volume初期化時だけcustom_appsへ配置する。
if [ ! -d "${app_dir}" ]; then
  rm -rf "${archive}" "${extract_dir}"
  mkdir -p "${extract_dir}"

  if [ -f "${NEXTCLOUD_USER_OIDC_ARCHIVE}" ]; then
    # airgap環境ではbind mountした事前取得済みarchiveからOIDC appを復元する。
    cp "${NEXTCLOUD_USER_OIDC_ARCHIVE}" "${archive}"
  else
    # online環境では公式releaseからOIDC appを復元する。
    curl -fsSL "${NEXTCLOUD_USER_OIDC_URL}" -o "${archive}"
  fi
  # 起動時downloadでも事前取得archiveでも、同じchecksumで固定して内容の漂流を防ぐ。
  echo "${NEXTCLOUD_USER_OIDC_SHA256}  ${archive}" | sha256sum -c -

  tar -xzf "${archive}" -C "${extract_dir}"
  rm -rf "${app_dir}"
  mv "${extract_dir}/user_oidc" "${app_dir}"
  chown -R www-data:www-data "${app_dir}"
  rm -rf "${archive}" "${extract_dir}"
fi

php /var/www/html/occ app:enable user_oidc
