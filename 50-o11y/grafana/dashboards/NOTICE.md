# Dashboard Notice

## 方針

- dashboardは、公式または公式に準ずる提供元を優先して採用する。
- dashboardを取り込む場合は、出典、license、取得日、変更内容をこのfileへ記録する。
- licenseが確認できないdashboard JSONは同梱せず、PromQLと画面構成のみを参考に自作する。
- dashboard JSONを追加した場合は、Grafana provisioningで読み込めることを確認する。

## 採用済みDashboard

| 対象 | 配置先 | 提供元 | License | 取得日 | 変更内容 |
| --- | --- | --- | --- | --- | --- |
| AMD Device Metrics Exporter | `services/amd-dashboard_gpu.json` | ROCm/device-metrics-exporter | Apache-2.0 | 2026-07-26 | Grafana provisioning用にdatasource参照を`Prometheus`へ変更した。 |
| AMD Device Metrics Exporter | `services/amd-dashboard_job.json` | ROCm/device-metrics-exporter | Apache-2.0 | 2026-07-26 | Grafana provisioning用にdatasource参照を`Prometheus`へ変更した。 |
| AMD Device Metrics Exporter | `services/amd-dashboard_node.json` | ROCm/device-metrics-exporter | Apache-2.0 | 2026-07-26 | Grafana provisioning用にdatasource参照を`Prometheus`へ変更した。 |
| AMD Device Metrics Exporter | `services/amd-dashboard_overview.json` | ROCm/device-metrics-exporter | Apache-2.0 | 2026-07-26 | Grafana provisioning用にdatasource参照を`Prometheus`へ変更した。 |
| AMD Device Metrics Exporter | `services/amd-dashboard_system.json` | ROCm/device-metrics-exporter | Apache-2.0 | 2026-07-26 | Grafana provisioning用にdatasource参照を`Prometheus`へ変更した。 |
| NVIDIA DCGM Exporter | `services/nvidia-dcgm-exporter-dashboard.json` | NVIDIA/dcgm-exporter | Apache-2.0 | 2026-07-26 | 変更なし。 |

## 自作Dashboard

| 対象 | 配置先 | 生成元 | License | 作成日 | 備考 |
| --- | --- | --- | --- | --- | --- |
| Open-WebUI | `services/open-webui.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | OpenTelemetry metricsとscrape状態を表示する。 |
| Cloudflared | `services/cloudflared.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | Tunnel metricsとscrape状態を表示する。 |
| Keycloak | `services/keycloak.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | 管理port metricsとscrape状態を表示する。 |
| CouchDB | `services/couchdb.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | Prometheus endpoint metricsとscrape状態を表示する。 |
| Nextcloud | `services/nextcloud.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | OpenMetrics endpoint metricsとscrape状態を表示する。 |
| Text Embeddings Inference | `services/text-embeddings-inference.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | Inference endpoint metricsとscrape状態を表示する。 |
| LiteLLM | `services/litellm.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | LiteLLM Prometheus metricsとscrape状態を表示する。 |
| SearXNG | `services/searxng.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | SearXNG metrics endpointのscrape状態を表示する。 |
| Gitea | `services/gitea.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | Gitea metricsとscrape状態を表示する。 |
| Qdrant | `services/qdrant.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | REST/gRPC metricsとscrape状態を表示する。 |
| PostgreSQL Exporters | `services/postgres-exporters.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | postgres_exporter metricsとscrape状態を表示する。 |
| Redis Exporters | `services/redis-exporters.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | redis_exporter metricsとscrape状態を表示する。 |
| MySQL Exporters | `services/mysqld-exporters.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | mysqld_exporter metricsとscrape状態を表示する。 |
| RabbitMQ | `services/rabbitmq.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | rabbitmq_prometheus metricsとscrape状態を表示する。 |
| ClickHouse | `services/clickhouse.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | ClickHouse Prometheus protocol metricsとscrape状態を表示する。 |
| MinIO | `services/minio.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | MinIO metricsとscrape状態を表示する。 |
| HTTP Probes | `services/http-probes.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | blackbox exporterのprobe結果を表示する。 |

## 採用候補

| 対象 | 提供元候補 | 確認事項 |
| --- | --- | --- |
| Prometheus | Prometheus公式またはGrafana Labs | dashboard JSONのlicense |
| Node Exporter | Prometheus公式またはGrafana Labs | dashboard JSONのlicense |
| cAdvisor | cAdvisor公式またはGrafana Labs | dashboard JSONのlicense |
| Grafana | Grafana Labs公式 | dashboard JSONのlicense |
| RabbitMQ | RabbitMQ公式 | dashboard JSONのlicense |
| Gitea | Grafana Cloud Integration | dashboard JSONのlicense |
| Qdrant | Qdrant公式docs | metrics定義をもとに自作するか |
| CouchDB | Apache CouchDB公式docs | metrics定義をもとに自作するか |
| Nextcloud | Nextcloud公式docs | metrics定義をもとに自作するか |

## References

- [Grafana dashboard provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
- [Grafana licensing](https://grafana.com/licensing/)
- [Prometheus exporters and integrations](https://prometheus.io/docs/instrumenting/exporters/)
- [ROCm Device Metrics Exporter](https://github.com/ROCm/device-metrics-exporter)
- [AMD Device Metrics Exporter Prometheus and Grafana integration](https://instinct.docs.amd.com/projects/device-metrics-exporter/en/latest/integrations/prometheus-grafana.html)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [NVIDIA DCGM Exporter documentation](https://docs.nvidia.com/datacenter/dcgm/latest/gpu-telemetry/dcgm-exporter.html)
