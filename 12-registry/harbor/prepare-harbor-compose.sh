#!/usr/bin/env bash
set -euo pipefail

# Harbor公式installerを置くdirectoryを指定する。
HARBOR_INSTALLER_DIR="${HARBOR_INSTALLER_DIR:-12-registry/harbor/installer}"

# Harborが生成したdocker-compose.ymlのcopy先を指定する。
HARBOR_COMPOSE_OUTPUT_DIR="${HARBOR_COMPOSE_OUTPUT_DIR:-12-registry/harbor/generated}"

# Harborのhost名、HTTP port、data directoryを指定する。
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-${PUBLIC_HOST:-localhost}}"
HARBOR_HTTP_HOST_PORT="${HARBOR_HTTP_HOST_PORT:-33600}"
HARBOR_DATA_VOLUME="${HARBOR_DATA_VOLUME:-./data}"

# Harborの初期admin passwordを指定する。
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD is required}"

if [ ! -x "$HARBOR_INSTALLER_DIR/prepare" ]; then
  echo "ERROR: $HARBOR_INSTALLER_DIR/prepare が見つからないか実行できません。" >&2
  echo "ERROR: Harbor offline installerを $HARBOR_INSTALLER_DIR に展開してください。" >&2
  exit 1
fi

if [ ! -f "$HARBOR_INSTALLER_DIR/harbor.yml.tmpl" ]; then
  echo "ERROR: $HARBOR_INSTALLER_DIR/harbor.yml.tmpl が見つかりません。" >&2
  exit 1
fi

# 公式templateを元にharbor.ymlを作る。追加toolへ依存しないためawkで必要なkeyだけ差し替える。
awk \
  -v harbor_hostname="$HARBOR_HOSTNAME" \
  -v harbor_http_port="$HARBOR_HTTP_HOST_PORT" \
  -v harbor_admin_password="$HARBOR_ADMIN_PASSWORD" \
  -v harbor_data_volume="$HARBOR_DATA_VOLUME" '
    /^hostname:/ {
      print "hostname: " harbor_hostname
      next
    }
    /^http:/ {
      in_http = 1
      print
      next
    }
    in_http == 1 && /^[[:space:]]+port:/ {
      print "  port: " harbor_http_port
      in_http = 0
      next
    }
    /^harbor_admin_password:/ {
      print "harbor_admin_password: " harbor_admin_password
      next
    }
    /^data_volume:/ {
      print "data_volume: " harbor_data_volume
      next
    }
    /^https:/ {
      skip_https = 1
      next
    }
    skip_https == 1 && /^[^[:space:]#]/ {
      skip_https = 0
    }
    skip_https == 1 {
      next
    }
    {
      print
    }
  ' "$HARBOR_INSTALLER_DIR/harbor.yml.tmpl" > "$HARBOR_INSTALLER_DIR/harbor.yml"

# Harbor公式prepareでdocker-compose.ymlを生成する。
(
  cd "$HARBOR_INSTALLER_DIR"
  ./prepare
)

mkdir -p "$HARBOR_COMPOSE_OUTPUT_DIR"
cp "$HARBOR_INSTALLER_DIR/docker-compose.yml" "$HARBOR_COMPOSE_OUTPUT_DIR/docker-compose.yml"

echo "generated: $HARBOR_COMPOSE_OUTPUT_DIR/docker-compose.yml"
