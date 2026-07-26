# 50-o11y

GrafanaとPrometheusを中心にしたobservability stack。

## 構成

- Grafana
- Prometheus
- Node Exporter
- cAdvisor
- Blackbox Exporter
- AMD Device Metrics Exporter
- NVIDIA DCGM Exporter（初期状態では無効）

Portainerは管理UIでありobservability基盤の中核ではないため、このstackには含めない。

## 起動

```bash
# o11y stackを起動する。
sudo docker compose --env-file .env --profile o11y up -d
```

AMD GPU metricsを有効化する場合:

```bash
# AMD GPU exporterに必要なROCm device nodeが存在することを確認する。
ls -l /dev/kfd /dev/dri

# AMD GPU exporterを追加で起動する。
sudo docker compose --env-file .env --profile o11y --profile amd-gpu up -d
```

AMD GPU metricsを使う場合は、`docker-compose.yml`の`amd-device-metrics-exporter` serviceと`prometheus/prometheus.yaml`のscrape設定をコメント解除してから、`amd-gpu` profileを併用する。`/dev/kfd`または`/dev/dri`が存在しないhostでは、AMD Device Metrics ExporterはGPU metricsを収集できない。

NVIDIA GPU metricsを有効化する場合は、`docker-compose.yml`の`nvidia-dcgm-exporter` serviceと`prometheus/prometheus.yaml`のscrape設定をコメント解除してから、`nvidia-gpu` profileを併用する。

期待値:

- Grafanaが`http://${PUBLIC_HOST}:35000`で応答する。
- Prometheusが`http://${PUBLIC_HOST}:35001`で応答する。
- Prometheusの`Status` - `Targets`に、host、container、probe対象が表示される。

失敗条件:

- `docker compose config --quiet`が失敗する。
- GrafanaまたはPrometheusのcontainerがunhealthyになる。
- Prometheusが`50-o11y/prometheus/prometheus.yaml`を読み込めない。

## 初期scrape対象

- `prometheus:9090`
- `grafana:3000`
- Open-WebUI OTLP metrics（Prometheusの`/api/v1/otlp/v1/metrics`へpush）
- `node-exporter:9100`
- `cadvisor:8080`
- `blackbox-exporter:9115`
- `cloudflare:20241`
- `keycloak:9000`
- `keycloak-https:9000`
- `couchdb:5984`
- `nextcloud:80`
- `tei-embedding:8000`
- `tei-reranking:8000`
- `litellm:4000`
- `searxng:8080`
- `gitea:3000`
- `qdrant:6333`
- `dify-qdrant:6333`
- `keycloak-postgres-exporter:9187`
- `langfuse-postgres-exporter:9187`
- `gitea-postgres-exporter:9187`
- `dify-postgres-exporter:9187`
- `zulip-postgres-exporter:9187`
- `pulp-postgres-exporter:9187`
- `nextcloud-redis-exporter:9121`
- `langfuse-redis-exporter:9121`
- `dify-redis-exporter:9121`
- `zulip-redis-exporter:9121`
- `pulp-redis-exporter:9121`
- `nextcloud-mysqld-exporter:9104`
- `leantime-mysqld-exporter:9104`
- `bookstack-mysqld-exporter:9104`
- `zulip-rabbitmq:15692`
- `langfuse-clickhouse:9363`
- `langfuse-minio:9000`

一部の対象は該当profileが起動していない場合にdownになる。これはstack分割されたCompose構成では許容する。

## Metrics対応

| 対象 | 対応 |
| --- | --- |
| Open-WebUI | OpenTelemetry metricsを有効化し、PrometheusのOTLP HTTP receiverへpushする。 |
| Keycloak | `KC_METRICS_ENABLED=true`で管理ポート`9000`の`/metrics`をscrapeする。 |
| Nextcloud | `openmetrics_allowed_clients`へDocker内部networkを追加し、`/metrics`をscrapeする。 |
| CouchDB | `/_node/_local/_prometheus`をbasic auth付きでscrapeする。 |
| LiteLLM | `prometheus` callbackを有効化し、`/metrics`をBearer認証付きでscrapeする。 |
| SearXNG | `open_metrics`を有効化し、`/metrics`をBasic Auth付きでscrapeする。 |
| Qdrant | `api-key` header付きで`/metrics`をscrapeする。 |
| PostgreSQL | `postgres_exporter`をo11y stackへ追加する。 |
| Redis/Valkey | `redis_exporter`をo11y stackへ追加する。 |
| MariaDB/MySQL | `mysqld_exporter`をo11y stackへ追加する。 |
| RabbitMQ | `rabbitmq_prometheus` pluginを有効化し、`15692`の`/metrics`をscrapeする。 |
| ClickHouse | Prometheus protocolを`9363`で有効化し、`/metrics`をscrapeする。 |
| MinIO | 内部network限定前提でPrometheus metrics認証をpublicにし、`/minio/metrics/v3`をscrapeする。 |

## Dashboard

次のdashboard JSONを同梱する。

- `grafana/dashboards/overview.json`: scrape対象、HTTP probe、Prometheus、Grafanaの概要を表示する。
- `grafana/dashboards/host-containers.json`: hostとcontainerのCPU、memory、disk、networkを表示する。
- `grafana/dashboards/services/open-webui.json`: Open-WebUIのHTTP request、latency、user数を表示する。自作dashboard。
- `grafana/dashboards/services/cloudflared.json`: Cloudflaredのtunnel接続、request、active sessionを表示する。自作dashboard。
- `grafana/dashboards/services/keycloak.json`: KeycloakのHTTP activity、DB pool、cacheを表示する。自作dashboard。
- `grafana/dashboards/services/couchdb.json`: CouchDBのscrape状態、HTTP request、DB read/writeを表示する。自作dashboard。
- `grafana/dashboards/services/nextcloud.json`: Nextcloudのscrape状態、user、share、storageを表示する。自作dashboard。
- `grafana/dashboards/services/text-embeddings-inference.json`: Text Embeddings Inferenceのscrape状態、HTTP request、latency、queueを表示する。自作dashboard。
- `grafana/dashboards/services/litellm.json`: LiteLLMのrequest、token、responseを表示する。自作dashboard。
- `grafana/dashboards/services/searxng.json`: SearXNGのscrape状態を表示する。自作dashboard。
- `grafana/dashboards/services/gitea.json`: GiteaのHTTP request、latency、process memoryを表示する。自作dashboard。
- `grafana/dashboards/services/qdrant.json`: QdrantのREST/gRPC responseとapp infoを表示する。自作dashboard。
- `grafana/dashboards/services/postgres-exporters.json`: PostgreSQL exporter群のup、connection、database sizeを表示する。自作dashboard。
- `grafana/dashboards/services/redis-exporters.json`: Redis exporter群のup、client、memoryを表示する。自作dashboard。
- `grafana/dashboards/services/mysqld-exporters.json`: MySQL exporter群のup、connection、queryを表示する。自作dashboard。
- `grafana/dashboards/services/rabbitmq.json`: RabbitMQのup、queue message、connectionを表示する。自作dashboard。
- `grafana/dashboards/services/clickhouse.json`: ClickHouseのquery、uptime、memoryを表示する。自作dashboard。
- `grafana/dashboards/services/minio.json`: MinIOのS3 request、usage、node数を表示する。自作dashboard。
- `grafana/dashboards/services/http-probes.json`: Blackbox ExporterのHTTP probe結果を表示する。自作dashboard。
- `grafana/dashboards/services/amd-dashboard_gpu.json`: ROCm Device Metrics Exporter公式dashboard（<https://github.com/ROCm/device-metrics-exporter/blob/main/grafana/dashboard_gpu.json>）。
- `grafana/dashboards/services/amd-dashboard_job.json`: ROCm Device Metrics Exporter公式dashboard（<https://github.com/ROCm/device-metrics-exporter/blob/main/grafana/dashboard_job.json>）。
- `grafana/dashboards/services/amd-dashboard_node.json`: ROCm Device Metrics Exporter公式dashboard（<https://github.com/ROCm/device-metrics-exporter/blob/main/grafana/dashboard_node.json>）。
- `grafana/dashboards/services/amd-dashboard_overview.json`: ROCm Device Metrics Exporter公式dashboard（<https://github.com/ROCm/device-metrics-exporter/blob/main/grafana/dashboard_overview.json>）。
- `grafana/dashboards/services/amd-dashboard_system.json`: ROCm Device Metrics Exporter公式dashboard（<https://github.com/ROCm/device-metrics-exporter/blob/main/grafana/dashboard_system.json>）。
- `grafana/dashboards/services/nvidia-dcgm-exporter-dashboard.json`: NVIDIA DCGM Exporter公式dashboard（<https://github.com/NVIDIA/dcgm-exporter/blob/main/grafana/dcgm-exporter-dashboard.json>、Grafana.com: <https://grafana.com/grafana/dashboards/12239>）。

サービス別dashboardは`grafana/generate_service_dashboards.py`で生成する。Grafana上では`services` folderに表示される。

外部dashboard JSONを採用する場合は、`grafana/dashboards/NOTICE.md`へ出典とlicenseを記録する。

## References

- [Grafana Docker installation](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/)
- [Prometheus installation](https://prometheus.io/docs/prometheus/latest/installation/)
- [Prometheus OpenTelemetry guide](https://prometheus.io/docs/guides/opentelemetry/)
- [Node Exporter](https://github.com/prometheus/node_exporter)
- [cAdvisor](https://github.com/google/cadvisor)
- [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter)
- [PostgreSQL Exporter](https://github.com/prometheus-community/postgres_exporter)
- [Redis Exporter](https://github.com/oliver006/redis_exporter)
- [MySQL Server Exporter](https://github.com/prometheus/mysqld_exporter)
- [Keycloak metrics](https://www.keycloak.org/observability/configuration-metrics)
- [CouchDB Prometheus endpoint](https://docs.couchdb.org/en/stable/api/server/common.html#node-node-name-prometheus)
- [Nextcloud OpenMetrics](https://docs.nextcloud.com/server/latest/admin_manual/configuration_monitoring/index.html#openmetrics)
- [LiteLLM Prometheus metrics](https://docs.litellm.ai/docs/proxy/prometheus)
- [SearXNG general settings](https://docs.searxng.org/admin/settings/settings_general.html)
- [RabbitMQ Prometheus plugin](https://www.rabbitmq.com/docs/prometheus)
- [ClickHouse Prometheus protocol](https://clickhouse.com/docs/interfaces/prometheus)
- [MinIO metrics and alerts](https://min.io/docs/minio/linux/operations/monitoring/metrics-and-alerts.html)
- [Open WebUI OpenTelemetry](https://docs.openwebui.com/reference/monitoring/otel/)
- [AMD Device Metrics Exporter](https://github.com/ROCm/device-metrics-exporter)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [Gitea configuration cheat sheet](https://docs.gitea.com/administration/config-cheat-sheet)
