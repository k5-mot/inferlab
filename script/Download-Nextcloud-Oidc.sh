#!/bin/sh

set -eu

version=8.10.1
expected_sha256=49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd
destination_directory="${1:-/srv/30-nextcloud/apps}"
destination_file="${destination_directory}/user_oidc-v${version}.tar.gz"
url="https://github.com/nextcloud-releases/user_oidc/releases/download/v${version}/user_oidc-v${version}.tar.gz"

mkdir -p "${destination_directory}"

echo "Download user_oidc v${version}"
curl -fL "${url}" -o "${destination_file}"

echo "${expected_sha256}  ${destination_file}" | sha256sum -c -
echo "Downloaded: ${destination_file}"
