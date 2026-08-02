#!/bin/sh
set -eu

# Prometheus設定はsecret値を含めずrepositoryへ置くため、起動時にplaceholderを置換する。
# 置換後の一時fileだけをPrometheusへ渡し、元templateはread-onlyのまま保つ。
awk '
BEGIN {
  couchdb_user = ENVIRON["COUCHDB_USER"]
  couchdb_password = ENVIRON["COUCHDB_PASSWORD"]
  litellm_master_key = ENVIRON["LITELLM_MASTER_KEY"]
  gsub(/\\/, "\\\\", couchdb_user)
  gsub(/&/, "\\&", couchdb_user)
  gsub(/\\/, "\\\\", couchdb_password)
  gsub(/&/, "\\&", couchdb_password)
  gsub(/\\/, "\\\\", litellm_master_key)
  gsub(/&/, "\\&", litellm_master_key)
}
{
  gsub(/__COUCHDB_USER__/, couchdb_user)
  gsub(/__COUCHDB_PASSWORD__/, couchdb_password)
  gsub(/__LITELLM_MASTER_KEY__/, litellm_master_key)
  print
}
' /etc/prometheus/prometheus.yaml > /tmp/prometheus.yaml

exec /bin/prometheus \
  --config.file=/tmp/prometheus.yaml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time="${PROMETHEUS_RETENTION_TIME:-30d}" \
  --web.enable-lifecycle \
  --web.enable-otlp-receiver
