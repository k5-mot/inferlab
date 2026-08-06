ARG NEXTCLOUD_VERSION=34.0.2-apache

FROM docker.io/library/nextcloud:${NEXTCLOUD_VERSION}

ARG USER_OIDC_VERSION=8.10.1

COPY apps/user_oidc-v${USER_OIDC_VERSION}.tar.gz \
    /tmp/user_oidc.tar.gz

RUN set -eux; \
    mkdir -p /usr/src/nextcloud/custom_apps; \
    tar -xzf /tmp/user_oidc.tar.gz \
    -C /usr/src/nextcloud/custom_apps; \
    test -d /usr/src/nextcloud/custom_apps/user_oidc; \
    chown -R www-data:www-data \
    /usr/src/nextcloud/custom_apps/user_oidc; \
    rm /tmp/user_oidc.tar.gz

COPY --chown=www-data:www-data \
    config/inferlab.config.php \
    /usr/src/nextcloud/config/inferlab.config.php

COPY --chmod=755 \
    bin/bootstrap \
    /usr/local/bin/inferlab-nextcloud-bootstrap
