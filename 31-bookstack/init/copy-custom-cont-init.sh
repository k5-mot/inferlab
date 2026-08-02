#!/bin/sh
set -eu

# LinuxServer imageの`/custom-cont-init.d`はvolume経由で渡す。
# host bindをBookStack本体へ直接mountしないことで、init scriptの権限をcontainer側に固定する。
rm -rf /target/*
cp -R /source/. /target/
chown -R root:root /target
find /target -type d -exec chmod 755 {} +
find /target -type f -exec chmod 755 {} +
