# コンテナイメージのバージョン調査（2026-08-21）

## 結論

2026-08-21 00:03 JST時点の`develop`について、全profileを展開したroot Composeの80サービス、65個のdistinct image参照、および稼働中の39コンテナ（35個のdistinct image）を調査した。

主要な更新候補は、Langfuse 4.1.0から4.15.0、Homepage 1.13.2から2.0.0、Kaneo 2.12.1から2.20.0、GitLab CE 19.2.1から19.2.4、Keycloak 26.7.0から26.7.2である。基盤系ではPostgreSQL 17.6から17.11、PostgreSQL 18.4から18.6、Prometheus 3.13.2から3.14.0などの更新を確認した。

バージョンとは別に、次の運用上の問題を確認した。

- BookStackとBookStack用MariaDBは現行Composeに存在しないが、2コンテナが稼働し続けている。
- `inferlab-langfuse-worker`は`unhealthy`である。
- `inferlab-searxng`は`Restarting`状態である。
- 稼働中のWiki.jsには旧group `32-wikijs`と旧port `33200`のCompose labelが残っている。現行`develop`の再デプロイ前の状態である。

## 調査方法と判定基準

稼働状態を確認するために`docker ps`を実行し、全profileの宣言を確認するために`STACK_NAME=inventory docker compose --profile '*' config`を実行した。外部イメージは、公式GitHub Releases API、Docker Hub Tags API、GHCRの公式package tags、Quay、または公式リリースページだけを根拠にした。取得は2026-08-20 23:30 JSTから2026-08-21 00:03 JSTに実施した。

判定は次の意味で使用する。

- `最新`: 現在値が確認できた最新の安定版と一致する。
- `更新あり`: より新しい安定版または同じ互換系列のpatch版を確認できる。
- `浮動tag`: `main`、majorのみ、または`latest`など、再pullで内容が変わり得る。
- `digest固定`: 内容は固定されるが、更新の採否はdigestを明示的に差し替える必要がある。
- `追跡不能`: ローカルbuildなど、外部レジストリの版だけでは最新版を定義できない。

PostgreSQL、Valkey、Node.jsなどは互換性を考慮し、同一major・同一variantの最新版を比較対象とした。RC、beta、nightly、dev tagは安定版から除外した。タグの存在とアプリケーション互換性は別問題であり、更新前に各サービスの移行手順を確認する必要がある。

表の対象区分は、`C+R`がCompose採用かつ稼働中、`C`がComposeのみ、`R`が稼働中のみを表す。

## Root Composeのimage参照

| 対象 | 現在のimage参照 | 確認できた最新版 | 判定 | 根拠・注意点 |
|---|---|---|---|---|
| C | `adorsys/keycloak-config-cli:6.5.1-26` | `6.5.1-26`系列 | 浮動tag | [公式tags](https://hub.docker.com/v2/repositories/adorsys/keycloak-config-cli/tags?page_size=100&ordering=last_updated&name=6.5.1)。末尾`26`はKeycloak 26互換系列を追跡するtag。 |
| C+R | `agentscope/qwenpaw:v2.1.0` | `v2.1.0` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/agentscope/qwenpaw/tags?page_size=100&ordering=last_updated&name=v2.)。`v2.1.1-beta.1`は除外。 |
| C | `amazon/aws-cli:2.36.14` | `2.36.27` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/amazon/aws-cli/tags?page_size=100&ordering=last_updated&name=2.36.)。bucket初期化用。 |
| C+R | `clickhouse/clickhouse-server:26.7.1` | `26.7.4` | 更新あり | [公式release](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.7.4.58-stable)。同一stable系列で比較。 |
| C+R | `cloudflare/cloudflared:2026.7.3` | `2026.8.2` | 更新あり | [公式release API](https://api.github.com/repos/cloudflare/cloudflared/releases/latest)。 |
| C | `eilandert/reprepro@sha256:7e4486…` | `latest` digest `sha256:96dbd4…` | digest固定（更新あり） | [公式tags](https://hub.docker.com/v2/repositories/eilandert/reprepro/tags?page_size=100&ordering=last_updated)。version tagがなく、機能版は比較不能。 |
| C+R | `grafana/grafana:13.1.1` | `13.2.0` | 更新あり | [公式release API](https://api.github.com/repos/grafana/grafana/releases/latest)。 |
| C+R | `langfuse/langfuse-worker:4.1.0` | `4.15.0` | 更新あり | [公式release API](https://api.github.com/repos/langfuse/langfuse/releases/latest)。現在unhealthy。webと同時更新が必要。 |
| C | `langfuse/langfuse:4.1.0` | `4.15.0` | 更新あり | [公式release API](https://api.github.com/repos/langfuse/langfuse/releases/latest)。workerと同時更新が必要。 |
| C | `langgenius/dify-agent-backend:1.16.1` | `1.16.1` | 最新 | [公式release API](https://api.github.com/repos/langgenius/dify/releases/latest)。Dify一式で揃える。 |
| C | `langgenius/dify-agent-local-sandbox:1.16.1` | `1.16.1` | 最新 | [公式release API](https://api.github.com/repos/langgenius/dify/releases/latest)。 |
| C | `langgenius/dify-api:1.16.1` | `1.16.1` | 最新 | [公式release API](https://api.github.com/repos/langgenius/dify/releases/latest)。worker/beatも同じimageを使用。 |
| C | `langgenius/dify-plugin-daemon:0.6.8-local` | `0.6.10-local` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/langgenius/dify-plugin-daemon/tags?page_size=100&ordering=last_updated&name=0.6.)。Dify本体との互換性確認が必要。 |
| C | `langgenius/dify-sandbox:0.2.15` | `0.2.15` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/langgenius/dify-sandbox/tags?page_size=100&ordering=last_updated&name=0.2.)。 |
| C | `langgenius/dify-web:1.16.1` | `1.16.1` | 最新 | [公式release API](https://api.github.com/repos/langgenius/dify/releases/latest)。 |
| C | `busybox:1.38.0` | `1.38.0` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/library/busybox/tags?page_size=100&ordering=last_updated&name=1.38.)。 |
| C+R | `couchdb:3.5.2.1` | `3.5.2.1` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/library/couchdb/tags?page_size=100&ordering=last_updated&name=3.5.)。 |
| C | `memcached:1.6.45-alpine` | `1.6.45-alpine` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/library/memcached/tags?page_size=100&ordering=last_updated&name=1.6.)。 |
| C+R | `nextcloud:34.0.2-apache` | `34.0.3-apache` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/library/nextcloud/tags?page_size=100&ordering=last_updated&name=34.)。 |
| C | `nginx:1.31.3-alpine` | `1.31.4-alpine` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/library/nginx/tags?page_size=100&ordering=last_updated&name=1.31.)。 |
| C | `postgres:15-alpine` | `15.19-alpine` | 浮動tag | [公式tags](https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&ordering=last_updated&name=15.)。major tagのためpatchが再pull時に変わる。 |
| C | `postgres:16-alpine` | `16.15-alpine` | 浮動tag | [公式tags](https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&ordering=last_updated&name=16.)。major tagのためpatchが再pull時に変わる。 |
| C+R | `postgres:17.6-alpine` | `17.11-alpine` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&ordering=last_updated&name=17.)。Wiki.js DB。 |
| C+R | `postgres:18.4-trixie` | `18.6-trixie` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&ordering=last_updated&name=18.)。3サービスで共有。 |
| C | `rabbitmq:4.2` | `4.2.9`（全体は`4.3.5`） | 浮動tag | [公式tags](https://hub.docker.com/v2/repositories/library/rabbitmq/tags?page_size=100&ordering=last_updated&name=4.2)。minor tagを追跡。 |
| C | `redis:8.8.0-alpine` | `8.8.1-alpine` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/library/redis/tags?page_size=100&ordering=last_updated&name=8.8.)。全体の新系列は8.10.0。 |
| C | `registry:3.1.1` | `3.1.1` | 最新 | [公式release API](https://api.github.com/repos/distribution/distribution/releases/latest)。 |
| C+R | `litellm/litellm:v1.94.1` | `v1.97.0` | 更新あり | [公式release API](https://api.github.com/repos/BerriAI/litellm/releases/latest)。RC/devは除外。 |
| C+R | `nousresearch/hermes-agent:v2026.8.3` | `v2026.8.18` | 更新あり | [公式release API](https://api.github.com/repos/NousResearch/hermes-agent/releases/latest)。永続化移行後の回帰確認が必要。 |
| C+R | `ollama/ollama:0.32.5` | `0.32.15` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/ollama/ollama/tags?page_size=100&ordering=last_updated&name=0.32.)。registry上の非RC tagを採用。 |
| C | `openitcockpit/createrepo_c:bullseye-0.17.0` | `bullseye-0.17.0` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/openitcockpit/createrepo_c/tags?page_size=100&ordering=last_updated)。配布tagが限定的。 |
| C+R | `prom/prometheus:v3.13.2` | `v3.14.0` | 更新あり | [公式release API](https://api.github.com/repos/prometheus/prometheus/releases/latest)。 |
| C+R | `qdrant/qdrant:v1.18.3` | `v1.19.0` | 更新あり | [公式release API](https://api.github.com/repos/qdrant/qdrant/releases/latest)。RAGとDifyで共有。 |
| C+R | `rustfs/rustfs:1.0.0-beta.12` | 安定版なし（最新pre-releaseは`1.0.0-rc.2`） | 追跡不能 | [公式tags](https://hub.docker.com/v2/repositories/rustfs/rustfs/tags?page_size=100&ordering=last_updated&name=1.0.0)。RCを安定版とは判定しない。 |
| C+R | `searxng/searxng:2026.7.3-80c9806de` | `2026.8.20-8d3dd0cd4` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=100&ordering=last_updated&name=2026.)。現在Restarting。 |
| C+R | `traefik/whoami:v1.11` | `v1.12.0` | 更新あり | [公式release API](https://api.github.com/repos/traefik/whoami/releases/latest)。 |
| C | `ubuntu/squid@sha256:6a097f…` | 公式`latest`と同digest | digest固定（最新） | [公式tags](https://hub.docker.com/v2/repositories/ubuntu/squid/tags?page_size=100&ordering=last_updated)。digestは`6.6-24.04_beta`にも対応し、channel名は安定版比較に不向き。 |
| C+R | `valkey/valkey:8.1.9-alpine3.24` | `8.1.9-alpine3.24` | 最新 | [公式tags](https://hub.docker.com/v2/repositories/valkey/valkey/tags?page_size=100&ordering=last_updated&name=8.1.)。全体の最新majorは9。 |
| C+R | `valkey/valkey:9.1.1-alpine3.24` | `9.1.1-alpine3.24` | 最新 | [公式release API](https://api.github.com/repos/valkey-io/valkey/releases/latest)。 |
| C | `ghcr.io/coder/code-marketplace:v2.4.2` | `v2.4.2` | 最新 | [公式release API](https://api.github.com/repos/coder/code-marketplace/releases/latest)。2サービスで使用。 |
| C+R | `ghcr.io/gethomepage/homepage:v1.13.2` | `v2.0.0` | 更新あり | [公式release API](https://api.github.com/repos/gethomepage/homepage/releases/latest)。major更新。 |
| C+R | `ghcr.io/google/cadvisor:v0.60.5` | `v0.60.5` | 最新 | [公式release API](https://api.github.com/repos/google/cadvisor/releases/latest)。 |
| C | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3` | `cpu-1.9.3` | 最新 | [公式release API](https://api.github.com/repos/huggingface/text-embeddings-inference/releases/latest)。embeddingとrerankingで共有。 |
| C+R | `ghcr.io/k5-mot/docling-serve-jp:v1.26.0` | `v1.30.0` | 更新あり | [公式package tags](https://github.com/k5-mot/docling-serve-jp/pkgs/container/docling-serve-jp)。GitHub releaseはないためregistry tagで判定。 |
| C+R | `ghcr.io/open-webui/mcpo:main` | 安定release `v0.0.20` | 浮動tag | [公式release API](https://api.github.com/repos/open-webui/mcpo/releases/latest)。`main`はcommit追従で再現性がない。 |
| C+R | `ghcr.io/open-webui/open-terminal:0.11.33` | `0.11.35` | 更新あり | [公式release API](https://api.github.com/repos/open-webui/open-terminal/releases/latest)。 |
| C+R | `ghcr.io/open-webui/open-webui:0.11.0` | `0.11.0` | 最新 | [公式release API](https://api.github.com/repos/open-webui/open-webui/releases/latest)。 |
| C+R | `ghcr.io/remsky/kokoro-fastapi-cpu:v0.7.0` | `v0.8.0` | 更新あり | [公式release API](https://api.github.com/repos/remsky/Kokoro-FastAPI/releases/latest)。 |
| C+R | `ghcr.io/requarks/wiki:2.5.314` | `2.5.314` | 最新 | [公式release API](https://api.github.com/repos/Requarks/wiki/releases/latest)。稼働側は旧directory/port label。 |
| C | `ghcr.io/usekaneo/kaneo:2.12.1` | `2.20.0` | 更新あり | [公式release API](https://api.github.com/repos/usekaneo/kaneo/releases/latest)。 |
| C | `ghcr.io/zulip/zulip-server:12.1-0` | `12.2-0` | 更新あり | [公式GHCR tags](https://github.com/zulip/docker-zulip/pkgs/container/zulip-server)。アプリreleaseは12.2。 |
| C | `gitlab/gitlab-ce:19.2.1-ce.0` | `19.2.4-ce.0` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=100&ordering=last_updated&name=19.2.)。backupとupgrade pathの確認が必要。 |
| C | `gitlab/gitlab-runner:alpine-v19.2.1` | `alpine-v19.2.2` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/gitlab/gitlab-runner/tags?page_size=100&ordering=last_updated&name=alpine-v19.2.)。register用も同じimage。 |
| C+R | Compose生成image `inventory-openclaw` | base `2026.7.1-browser`はrelease系列内最新 | 追跡不能（build） | [OpenClaw公式release API](https://api.github.com/repos/openclaw/openclaw/releases/latest)。明示image名がなくproject名から生成される。build補助の`uv:0.12.0`には`0.12.5`への更新あり。 |
| C | `local/llm-wiki-platform:0.1.0` | 比較不能 | 追跡不能（build） | ローカルソースからbuild。Dockerfile baseの`python:3.12.11-slim-bookworm`には`3.12.14-slim-bookworm`への更新あり。 |
| C+R | `local/oikb:latest` | upstream release `v0.4.0` | 浮動tag（local build） | [OIKB公式release API](https://api.github.com/repos/open-webui/oikb/releases/latest)。`ghcr.io/open-webui/oikb:latest`をbaseにpatchするため再build結果が変わり得る。 |
| C+R | `local/openkb:0.5.0rc1` | 比較不能 | 追跡不能（build） | ローカルソースからbuild。稼働中はtagを失ったimage IDで、別Compose projectとして起動している。Python baseには3.12.14への更新あり。 |
| C | `nginxinc/nginx-unprivileged:1.31.3-alpine` | `1.31.4-alpine` | 更新あり | [公式tags](https://hub.docker.com/v2/repositories/nginxinc/nginx-unprivileged/tags?page_size=100&ordering=last_updated&name=1.31.)。deb/rpm配信用。 |
| C | `node:22-alpine` | `22.22.3-alpine` | 浮動tag | [公式tags](https://hub.docker.com/v2/repositories/library/node/tags?page_size=100&ordering=last_updated&name=22.22.)。Node 22 majorを追跡。npm importer用。 |
| C | `pypiserver/pypiserver:v2.4.1` | `v2.4.1` | 最新 | [公式release API](https://api.github.com/repos/pypiserver/pypiserver/releases/latest)。 |
| C+R | `quay.io/keycloak/keycloak:26.7.0` | `26.7.2` | 更新あり | [公式release API](https://api.github.com/repos/keycloak/keycloak/releases/latest)。HTTP/HTTPSの2サービスで共有。 |
| C+R | `quay.io/prometheus/blackbox-exporter:v0.28.0` | `v0.28.0` | 最新 | [公式release API](https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest)。 |
| C+R | `quay.io/prometheus/node-exporter:v1.12.1` | `v1.12.1` | 最新 | [公式release API](https://api.github.com/repos/prometheus/node_exporter/releases/latest)。 |
| C | `verdaccio/verdaccio:6.9.0` | `6.10.0` | 更新あり | [公式release API](https://api.github.com/repos/verdaccio/verdaccio/releases/latest)。 |
| C | `zulip/zulip-postgresql:14` | version固定の最新版は比較不能 | 浮動tag | [公式tags](https://hub.docker.com/v2/repositories/zulip/zulip-postgresql/tags?page_size=100&ordering=last_updated&name=14)。Zulip専用のmajor tagのみ。 |

## Composeから外れた稼働中イメージ

| 対象 | 現在のimage参照 | 確認できた最新版 | 判定 | 根拠・注意点 |
|---|---|---|---|---|
| R | `lscr.io/linuxserver/bookstack:26.05.2` | `v26.05.3-ls280` | 更新あり・孤立 | [公式release API](https://api.github.com/repos/linuxserver/docker-bookstack/releases/latest)。現行Composeから削除済みなので更新ではなく停止・撤去対象。 |
| R | `lscr.io/linuxserver/mariadb:11.4.12` | `11.8.8-r0-ls227` | 更新あり・孤立 | [公式release API](https://api.github.com/repos/linuxserver/docker-mariadb/releases/latest)。BookStack専用DBであり、データ退避を確認してから撤去する。 |

## 推奨する対応順

1. BookStackの必要データを確認し、孤立した2コンテナと関連volumeの撤去手順を決める。
2. Langfuse WorkerとSearXNGの障害原因を、バージョン更新とは切り分けて診断する。
3. 現行`develop`を再デプロイし、Wiki.jsなどのdirectory・port変更を稼働環境へ反映する。
4. patch更新を優先し、PostgreSQL、GitLab、Keycloak、Prometheus、Nextcloud、Nginx系をサービスごとに検証する。
5. LangfuseとHomepageの大きな更新はmigration notesを確認し、個別の変更として実施する。
6. `main`、`latest`、majorのみの浮動tagをimmutableなversionまたはdigestへ置き換える。

## References

- [Docker Hub Tags API](https://docs.docker.com/docker-hub/api/latest/)
- [GitHub REST API: Releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Quay Container Registry API](https://docs.quay.io/api/)
- 表中にリンクした各プロジェクトの公式release API、公式package tags、および公式registry tags
