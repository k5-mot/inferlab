# 50-o11y

GrafanaとPrometheusを中心にしたobservability stack。

## 構成

- Grafana
- Prometheus
- Node Exporter
- cAdvisor
- Blackbox Exporter

Portainerは管理UIでありobservability基盤の中核ではないため、このstackには含めない。

## 起動

```bash
# o11y stackを起動する。
sudo docker compose --env-file .env --profile o11y up -d
```

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
- `node-exporter:9100`
- `cadvisor:8080`
- `blackbox-exporter:9115`
- `cloudflare:20241`
- `tei-embedding:8000`
- `tei-reranking:8000`
- `gitea:3000`
- `qdrant:6333`
- `dify-qdrant:6333`

一部の対象は該当profileが起動していない場合にdownになる。これはstack分割されたCompose構成では許容する。

## 追加予定のmetrics有効化

| 対象 | 対応 |
| --- | --- |
| Keycloak | `KC_METRICS_ENABLED=true`を設定する。 |
| Nextcloud | `openmetrics`の許可clientをPrometheus containerへ合わせる。 |
| CouchDB | `/_node/_local/_prometheus`をbasic auth付きでscrapeする。 |
| LiteLLM | Prometheus callbackを有効化する。 |
| RabbitMQ | `rabbitmq_prometheus` pluginを有効化する。 |
| PostgreSQL | `postgres_exporter`を追加する。 |
| Redis/Valkey | `redis_exporter`を追加する。 |
| MariaDB/MySQL | `mysqld_exporter`を追加する。 |
| Open WebUI | OpenTelemetry Collector経由でPrometheusへ接続する。 |

## Dashboard

外部dashboard JSONは初期状態では同梱しない。採用する場合は、`grafana/dashboards/NOTICE.md`へ出典とlicenseを記録する。

## References

- [Grafana Docker installation](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/)
- [Prometheus installation](https://prometheus.io/docs/prometheus/latest/installation/)
- [Node Exporter](https://github.com/prometheus/node_exporter)
- [cAdvisor](https://github.com/google/cadvisor)
- [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter)
- [Gitea configuration cheat sheet](https://docs.gitea.com/administration/config-cheat-sheet)

