# inferlab

ローカルAI実験環境をDocker Composeでまとめて起動するstack。

## Usage

通常起動は`dc.sh`を使う。

```bash
# 標準profileを順番に起動する。
sudo ./dc.sh up --remove-orphans
```

期待結果:

- 標準profileのserviceが順番に起動する。
- 主要serviceが`running`または`healthy`になる。

失敗条件:

- `docker compose config`相当の設定解決でエラーになる。
- 必須serviceのcontainerが`unhealthy`になる。

標準profileは`common`、`infra`、`inference`、`webui`、`storage`、`o11y`、`llmops`。

全profileをまとめてComposeへ渡す場合:

```bash
# 標準profileを1つのdocker composeコマンドで起動する。
sudo ./dc.sh up-full --remove-orphans
```

初回設定は[docs/INITIAL_SETUP.md](docs/INITIAL_SETUP.md)を参照する。

## Profiles

| Profile | Compose file | 主なservice |
| --- | --- | --- |
| `common` | `00-common/docker-compose.yml` | Keycloak、Keycloak HTTPS、Homepage |
| `infra` | `01-infra/docker-compose.yml` | Cloudflare Tunnel、CouchDB |
| `inference` | `10-inference/docker-compose.yml` | LiteLLM、Ollama、Text Embeddings Inference、Hermes-Agent |
| `webui` | `11-webui/docker-compose.yml` | Open-WebUI、Open-Terminal、Docling、SearXNG、VOICEVOX、Qdrant |
| `storage` | `12-storage/docker-compose.yml` | Nextcloud、OIKB |
| `automation` | `13-automation/docker-compose.yml` | Dify |
| `team-chat` | `20-team-chat/docker-compose.yml` | Zulip |
| `team-project` | `21-team-project/docker-compose.yml` | Leantime |
| `team-wiki` | `22-team-wiki/docker-compose.yml` | BookStack |
| `team-git` | `23-team-git/docker-compose.yml` | Gitea |
| `developer` | `30-developer/docker-compose.yml` | Pulp custom image |
| `o11y` | `50-o11y/docker-compose.yml` | Grafana、Prometheus、Node Exporter、cAdvisor、Blackbox Exporter |
| `llmops` | `51-llmops/docker-compose.yml` | Langfuse、ClickHouse、MinIO、Redis、PostgreSQL |

`amd-gpu`と`nvidia-gpu`はGPU exporter用の任意profile。対応hostで`50-o11y/docker-compose.yml`と`50-o11y/prometheus/prometheus.yaml`の該当コメントを解除して使う。

## Images

標準profileで使う主なimage:

- Keycloak: `quay.io/keycloak/keycloak:26.7.0`
- Homepage: `ghcr.io/gethomepage/homepage:v1.13.2`
- Cloudflared: `docker.io/cloudflare/cloudflared:2026.6.0`
- CouchDB: `docker.io/library/couchdb:3.5.2.1`
- LiteLLM: `docker.io/litellm/litellm:v1.91.0`
- Ollama: `docker.io/ollama/ollama:0.31.1`
- Text Embeddings Inference: `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3`
- Hermes-Agent: `docker.io/nousresearch/hermes-agent:main`
- Open-WebUI: `ghcr.io/open-webui/open-webui:0.10.2`
- Open-Terminal: `ghcr.io/open-webui/open-terminal:0.11.33`
- Docling: `ghcr.io/k5-mot/docling-serve-jp:v1.26.0`
- SearXNG: `docker.io/searxng/searxng:2026.7.3-80c9806de`
- VOICEVOX Engine: `docker.io/voicevox/voicevox_engine:cpu-0.25.2`
- VOICEVOX OpenAI TTS: `ghcr.io/sunwood-ai-labs/voicevox-openai-tts:0.2.0`
- Qdrant: `docker.io/qdrant/qdrant:v1.18.2`
- Nextcloud: `docker.io/library/nextcloud:34.0.1-apache`
- OIKB: `ghcr.io/open-webui/oikb:0.3.6`
- Pulp Minimal: `ghcr.io/k5-mot/pulp-minimal:3.114.0`
- Pulp Web: `ghcr.io/k5-mot/pulp-web:3.114.0`
- Grafana: `docker.io/grafana/grafana:13.1.1`
- Prometheus: `docker.io/prom/prometheus:v3.13.1`
- Node Exporter: `quay.io/prometheus/node-exporter:v1.12.1`
- cAdvisor: `ghcr.io/google/cadvisor:v0.60.5`
- Blackbox Exporter: `quay.io/prometheus/blackbox-exporter:v0.28.0`
- Langfuse: `docker.io/langfuse/langfuse:3.212.0`
- Langfuse Worker: `docker.io/langfuse/langfuse-worker:3.212.0`
- ClickHouse: `docker.io/clickhouse/clickhouse-server:25.8.28.1`
- MinIO: `cgr.dev/chainguard/minio:latest`

任意profileのimage一覧は`script/download-stack-images.ps1`も参照する。

## Observability

`o11y` profileはGrafanaとPrometheusを起動する。Grafana dashboardは`50-o11y/grafana/dashboards`配下にあり、サービス別dashboardは`50-o11y/grafana/dashboards/services`に配置する。

```bash
# o11y profileだけを起動する。
sudo docker compose --env-file .env --profile o11y up -d
```

期待結果:

- Grafanaが`http://${PUBLIC_HOST}:35000`で応答する。
- Prometheusが`http://${PUBLIC_HOST}:35001`で応答する。

失敗条件:

- GrafanaまたはPrometheusが`unhealthy`になる。
- Prometheusが設定fileを読み込めない。

詳細は[50-o11y/README.md](50-o11y/README.md)を参照する。

## Offline Images

`script/download-stack-images.ps1`は、現在のCompose構成で使う外部imageを`images/`へ保存する。ローカルbuild imageは対象外。

```powershell
# 現在のstack imageをimages/へ保存する。
pwsh -NoProfile -File script/download-stack-images.ps1
```

期待結果:

- `images/`に対象imageごとの`.tar`が作成される。

失敗条件:

- `crane`が見つからない。
- いずれかのimage pullが失敗する。
