# Dashboard Notice

## 方針

- dashboardは、公式または公式に準ずる提供元を優先して採用する。
- dashboardを取り込む場合は、出典、license、取得日、変更内容をこのfileへ記録する。
- licenseが確認できないdashboard JSONは同梱せず、PromQLと画面構成のみを参考に自作する。
- dashboard JSONを追加した場合は、Grafana provisioningで読み込めることを確認する。

## 採用済みDashboard

| 対象 | 配置先 | 提供元 | License | 取得日 | 変更内容 |
| --- | --- | --- | --- | --- | --- |
| なし | - | - | - | - | Services folderは自作dashboardだけを配置する。 |

## 自作Dashboard

| 対象 | 配置先 | 生成元 | License | 作成日 | 備考 |
| --- | --- | --- | --- | --- | --- |
| Cloudflared | `services/cloudflared.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | Cloudflare公式metricsとGrafana Labs dashboardの構成分類を参考に、Tunnel health、traffic、session、edge location、latency、process metricsを表示する。 |
| CouchDB | `services/couchdb.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | Prometheus endpoint metricsとscrape状態を表示する。 |
| GPU | `services/gpu.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-08-02 | NVIDIA DCGMとAMD Device Metrics Exporterの代表metricsを表示する。 |
| Keycloak | `services/keycloak.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | HTTP、DB pool、cache、JVM metricsを表示する。 |
| Nextcloud | `services/nextcloud.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | OpenMetrics endpoint metricsとscrape状態を表示する。 |
| Open-WebUI | `services/open-webui.json` | `grafana/generate_service_dashboards.py` | 自作、外部dashboard不使用 | 2026-07-26 | OpenTelemetry metrics、user数、route hotspot、blackbox疎通状態を表示する。 |

## 採用候補

| 対象 | 提供元候補 | 確認事項 |
| --- | --- | --- |
| Prometheus | Prometheus公式またはGrafana Labs | dashboard JSONのlicense |
| Node Exporter | Prometheus公式またはGrafana Labs | dashboard JSONのlicense |
| cAdvisor | cAdvisor公式またはGrafana Labs | dashboard JSONのlicense |
| Grafana | Grafana Labs公式 | dashboard JSONのlicense |
| RabbitMQ | RabbitMQ公式 | dashboard JSONのlicense |
| Qdrant | Qdrant公式docs | metrics定義をもとに自作するか |
| CouchDB | Apache CouchDB公式docs | metrics定義をもとに自作するか |
| Nextcloud | Nextcloud公式docs | metrics定義をもとに自作するか |

## References

- [Grafana dashboard provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
- [Grafana licensing](https://grafana.com/licensing/)
- [Cloudflare Tunnel metrics](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/monitor-tunnels/metrics/)
- [Monitor Cloudflare Tunnel with Grafana](https://developers.cloudflare.com/cloudflare-one/tutorials/grafana/)
- [Grafana Labs Cloudflare Tunnel dashboard](https://grafana.com/grafana/dashboards/24874-cloudflare-tunnel/)
- [Prometheus exporters and integrations](https://prometheus.io/docs/instrumenting/exporters/)
- [ROCm Device Metrics Exporter](https://github.com/ROCm/device-metrics-exporter)
- [AMD Device Metrics Exporter Prometheus and Grafana integration](https://instinct.docs.amd.com/projects/device-metrics-exporter/en/latest/integrations/prometheus-grafana.html)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [NVIDIA DCGM Exporter documentation](https://docs.nvidia.com/datacenter/dcgm/latest/gpu-telemetry/dcgm-exporter.html)
