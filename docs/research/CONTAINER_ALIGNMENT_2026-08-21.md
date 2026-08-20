# コンテナ最新版更新と依存イメージ統一の追加調査（2026-08-21）

## 結論

root Composeの全profileと`script/Download-Images.ps1`を照合した結果、アプリケーション本体は確認できた最新安定版へ更新できる。一方、DB、Valkey、RustFSなどの状態を持つ依存コンテナは、同一major内のpatch更新に限定し、同じmajor・variantを使うサービスでは完全に同じタグへ揃えるのが安全である。

具体的には次の統一が可能である。

- PostgreSQL 18系のKeycloak、Nextcloud、Langfuseは`postgres:18.6-trixie`へ統一する。
- DifyのPostgreSQL 15系は本体と初期化サービスを`postgres:15.19-alpine`へ統一する。
- DifyとZulipで現在採用しているRedis 8系を維持する場合は、両方を`redis:8.10.0-alpine`へ統一する。ただし、これは両製品の公式Composeより新しいmajorであり、統合テストが必要である。
- NextcloudのValkey 8系は`valkey:8.1.9-alpine3.24`、LangfuseのValkey 9系は`valkey:9.1.1-alpine3.24`を維持する。majorをまたいで一方へ揃えない。
- LangfuseとOIKBのRustFSは`rustfs:1.0.0-beta.12`のまま完全一致させる。Docker Hubにはより新しいRC tagがあるが、公式GitHub Releaseの最新版はbeta.12で、RC境界には混在運用の非互換報告もある。

`script/Download-Images.ps1`は現在root Composeと一致していない。特にClickHouseが別系列で、Wiki.js、PostgreSQL 17、Langfuse用Valkey 9が不足し、Composeから消えたBookStack用MariaDBと未使用MySQL、Alpineが残っている。更新時は手書き差分ではなく、root Composeの解決済みimage集合との一致を検証する必要がある。

## 調査範囲と判定方法

2026-08-21 JST時点の`develop`を対象に、root `docker-compose.yml`からincludeされる全Composeを全profileで展開し、`script/Download-Images.ps1`の`$Images`と`$LocalImages`も確認した。最新版は公式GitHub Releases、公式container registryのtags API、公式Docker Compose、公式製品文書だけで判定した。

表の「推奨」は次の優先順位で決めた。

1. アプリケーションは最新の安定releaseを採用する。
2. 状態を持つ依存サービスは同じmajor内の最新版を採用する。
3. 製品が専用imageまたは特定majorを公式Composeで指定する場合は、その互換性境界を優先する。
4. `main`、`latest`、majorだけの浮動tagは、確認できる安定版tagまたはdigestへ固定する。
5. RC、beta、nightlyは、安定版が存在しない製品を除いて最新版とは扱わない。

## アプリケーションと主要サービスの推奨タグ

| 用途 | 現行Compose | 現行Download script | 推奨タグ | 根拠と注意点 |
|---|---|---|---|---|
| Homepage | `v1.13.2` | `v1.13.2` | `v2.0.0` | [公式release](https://github.com/gethomepage/homepage/releases/tag/v2.0.0)。major更新なので設定、widget、認証のsmoke testが必要。 |
| Cloudflared | `2026.7.3` | `2026.7.3` | `2026.8.2` | [公式release API](https://api.github.com/repos/cloudflare/cloudflared/releases/latest)。 |
| LiteLLM | `v1.94.1` | `v1.94.1` | `v1.97.0` | [公式release API](https://api.github.com/repos/BerriAI/litellm/releases/latest)。proxy起動とmodel routingを確認する。 |
| Ollama | `0.32.5` | `0.32.5` | `0.32.15` | [公式tags](https://hub.docker.com/v2/repositories/ollama/ollama/tags?page_size=100&ordering=last_updated&name=0.32.)。initサービスも同じタグへ揃える。 |
| TEI | `cpu-1.9.3` | `cpu-1.9.3` | `cpu-1.9.3` | [公式release API](https://api.github.com/repos/huggingface/text-embeddings-inference/releases/latest)。embeddingとrerankingを同じタグで維持する。 |
| Kokoro FastAPI | `v0.7.0` | `v0.7.0` | `v0.8.0` | [公式release](https://github.com/remsky/Kokoro-FastAPI/releases/tag/v0.8.0)。音声生成APIの互換確認が必要。 |
| Hermes Agent | `v2026.8.3` | `v2026.8.3` | `v2026.8.18` | [公式release API](https://api.github.com/repos/NousResearch/hermes-agent/releases/latest)。永続化volumeと再起動後のsession復元を確認する。 |
| QwenPaw | `v2.1.0` | `v2.1.0` | `v2.1.0` | [公式tags](https://hub.docker.com/v2/repositories/agentscope/qwenpaw/tags?page_size=100&ordering=last_updated&name=v2.)。betaは除外。 |
| Docling Serve JP | `v1.26.0` | `v1.26.0` | `v1.30.0` | [公式package](https://github.com/k5-mot/docling-serve-jp/pkgs/container/docling-serve-jp)。RAG側の応答schemaを確認する。 |
| Qdrant | `v1.18.3` | `v1.18.3` | `v1.19.0` | [公式release](https://github.com/qdrant/qdrant/releases/tag/v1.19.0)。RAGとDifyを同時に揃え、storage backup後に起動する。 |
| Registry | `3.1.1` | `3.1.1` | `3.1.1` | [公式release API](https://api.github.com/repos/distribution/distribution/releases/latest)。 |
| PyPI server | `v2.4.1` | `v2.4.1` | `v2.4.1` | [公式release API](https://api.github.com/repos/pypiserver/pypiserver/releases/latest)。 |
| Verdaccio | `6.9.0` | `6.9.0` | `6.10.0` | [公式release API](https://api.github.com/repos/verdaccio/verdaccio/releases/latest)。package publish/installを確認する。 |
| Code Marketplace | `v2.4.2` | `v2.4.2` | `v2.4.2` | [公式release API](https://api.github.com/repos/coder/code-marketplace/releases/latest)。本体とimporterを同じタグで維持する。 |
| Open WebUI | `0.11.0` | `0.11.0` | `0.11.0` | [公式release API](https://api.github.com/repos/open-webui/open-webui/releases/latest)。 |
| Open Terminal | `0.11.33` | `0.11.33` | `0.11.35` | [公式release API](https://api.github.com/repos/open-webui/open-terminal/releases/latest)。 |
| MCPO | `main` | `main` | `main@sha256:1e82c9555c19e50b80745705f32b47a2647589f35279527b5118ecd3a71bd467` | [公式release](https://github.com/open-webui/mcpo/releases/tag/v0.0.20)に対応するGHCR version tagは公開されていない。2026-08-21時点の公式`main` manifest list digestへ固定し、浮動を止める。 |
| SearXNG | `2026.7.3-80c9806de` | 同左 | `2026.8.20-8d3dd0cd4` | [公式tags](https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=100&ordering=last_updated&name=2026.)。現行の再起動障害を先に特定し、設定互換性を確認してから更新する。 |
| OIKB | local build | local build | upstream `0.4.0`をbaseに固定 | [公式release](https://github.com/open-webui/oikb/releases/tag/v0.4.0)。GHCRに実在する`ghcr.io/open-webui/oikb:0.4.0`へ固定する。 |
| Langfuse Web / Worker | `4.1.0` | `4.1.0` | `4.15.0` | [公式release](https://github.com/langfuse/langfuse/releases/tag/v4.15.0)。WebとWorkerを必ず同時に揃え、DBとClickHouse migrationの完了を確認する。 |
| Dify本体 | `1.16.1` | `1.16.1` | `1.16.1` | [公式release API](https://api.github.com/repos/langgenius/dify/releases/latest)。api、worker、beat、web、agent-backend、local-sandboxをrelease単位で揃える。 |
| Dify Sandbox | `0.2.15` | `0.2.15` | `0.2.15` | [Dify 1.16.1公式Compose](https://github.com/langgenius/dify/blob/1.16.1/docker/docker-compose.yaml)。 |
| Dify Plugin Daemon | `0.6.8-local` | `0.6.8-local` | `0.6.8-local`を暫定維持 | [Dify 1.16.1公式Compose](https://github.com/langgenius/dify/blob/1.16.1/docker/docker-compose.yaml)は`0.6.3-local`を指定する。registry最新の`0.6.10-local`へ単独更新すると、最新Dify releaseの検証済み組み合わせからさらに外れる。現行0.6.8にも上流の互換性根拠はないため、次のDify releaseに追随するまで個別更新を保留する。 |
| Nextcloud | `34.0.2-apache` | 同左 | `34.0.3-apache` | [公式tags](https://hub.docker.com/v2/repositories/library/nextcloud/tags?page_size=100&ordering=last_updated&name=34.)。maintenance releaseは速やかな適用が公式推奨。 |
| Wiki.js | `2.5.314` | なし | `2.5.314` | [公式release API](https://api.github.com/repos/Requarks/wiki/releases/latest)。scriptへ追加し、現行Composeを再デプロイする。 |
| Kaneo | `2.12.1` | `2.12.1` | `2.20.0` | [公式release](https://github.com/usekaneo/kaneo/releases/tag/v2.20.0)と[公式Compose](https://github.com/usekaneo/kaneo/blob/v2.20.0/compose.yml)。起動時DB migration完了とhealth endpointを確認する。 |
| Zulip | `12.1-0` | `12.1-0` | `12.2-0` | [公式12.2 Compose](https://github.com/zulip/docker-zulip/blob/12.2-0/compose.yaml)。専用PostgreSQL 14は維持する。 |
| Keycloak | `26.7.0` | `26.7.0` | `26.7.2` | [公式release](https://github.com/keycloak/keycloak/releases/tag/26.7.2)。HTTP/HTTPSの2サービスを同じタグにする。 |
| Keycloak Config CLI | `6.5.1-26` | `6.5.1-26` | 同左 | [公式tags](https://hub.docker.com/v2/repositories/adorsys/keycloak-config-cli/tags?page_size=100&ordering=last_updated&name=6.5.1)。Keycloak 26互換系列を維持する。 |
| GitLab CE | `19.2.1-ce.0` | 同左 | `19.2.4-ce.0` | [公式tags](https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=100&ordering=last_updated&name=19.2.)。19.2はrequired upgrade stopで、同minorの最新patch採用が公式推奨。 |
| GitLab Runner | `alpine-v19.2.1` | 同左 | `alpine-v19.2.2` | [公式tags](https://hub.docker.com/v2/repositories/gitlab/gitlab-runner/tags?page_size=100&ordering=last_updated&name=alpine-v19.2.)。register用と常駐runnerを同じタグにする。GitLab Serverとpatch番号が一致する必要はない。 |
| CouchDB | `3.5.2.1` | `3.5.2.1` | `3.5.2.1` | [公式tags](https://hub.docker.com/v2/repositories/library/couchdb/tags?page_size=100&ordering=last_updated&name=3.5.)。 |
| Grafana | `13.1.1` | `13.1.1` | `13.2.0` | [公式release API](https://api.github.com/repos/grafana/grafana/releases/latest)。dashboardとdatasource migrationを確認する。 |
| Prometheus | `v3.13.2` | `v3.13.2` | `v3.14.0` | [公式release API](https://api.github.com/repos/prometheus/prometheus/releases/latest)。起動後にruleとtargetを確認する。 |
| Node Exporter | `v1.12.1` | 同左 | `v1.12.1` | [公式release API](https://api.github.com/repos/prometheus/node_exporter/releases/latest)。 |
| Blackbox Exporter | `v0.28.0` | 同左 | `v0.28.0` | [公式release API](https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest)。 |
| cAdvisor | `v0.60.5` | 同左 | `v0.60.5` | [公式release API](https://api.github.com/repos/google/cadvisor/releases/latest)。 |
| Whoami | `v1.11` | `v1.11` | `v1.12.0` | [公式release API](https://api.github.com/repos/traefik/whoami/releases/latest)。 |

## 依存コンテナの推奨タグ

| 依存サービス | 利用箇所 | 現行タグ | 推奨タグ | 統一・互換性判断 |
|---|---|---|---|---|
| PostgreSQL | Keycloak、Nextcloud、Langfuse | `18.4-trixie` | `18.6-trixie` | 3サービスを完全一致させる。Keycloak 26.7とNextcloud 34はPostgreSQL 18を公式にサポートし、Langfuse v4はPostgreSQL 15以上を要件とする。 |
| PostgreSQL | Dify、Dify DB init | `15-alpine` | `15.19-alpine` | 2サービスを完全一致させ、浮動major tagをpatch固定へ変更する。Dify 1.16.1公式ComposeもPostgreSQL 15を採用する。 |
| PostgreSQL | Kaneo | `16-alpine` | `16.15-alpine` | 公式Kaneo 2.20.0 Composeのmajor 16を維持し、patchを固定する。 |
| PostgreSQL | Wiki.js | `17.6-alpine` | `17.11-alpine` | 同一majorのpatch更新。`Download-Images.ps1`へ追加する。 |
| PostgreSQL | Zulip | `zulip/zulip-postgresql:14` | 同左 | Zulipが拡張を追加した専用imageであり、公式12.2 Composeもこのtagを指定する。標準PostgreSQLや別majorへ置換しない。 |
| PostgreSQL | GitLab | Omnibus image内蔵 | GitLab imageに追随 | 外部DBコンテナではない。GitLabのupgrade pathとbackground migrationを優先する。 |
| Valkey | Nextcloud | `8.1.9-alpine3.24` | 同左 | Valkey 8系の最新patch。NextcloudはRedis互換backendとしてValkeyが動作すると説明するが、正式試験対象はRedisである。 |
| Valkey | Langfuse | `9.1.1-alpine3.24` | 同左 | Valkey 9系の最新patch。LangfuseはRedis/Valkeyを明示的に構成要素として扱う。Nextcloudとはmajorが異なるため統一しない。 |
| Redis | Dify、Zulip | `8.8.0-alpine` | `8.10.0-alpine` | 現在のmajor 8を維持して完全一致させる案。ただしDify 1.16.1公式Composeは`redis:6-alpine`、Zulip 12.2公式Composeは浮動`redis:alpine`である。先にbackupを取得し、queue、cache、session、再起動後の永続化を検証する。保守性を最優先する場合は製品ごとの公式tagへ戻し、統一対象外にする。 |
| RustFS | Langfuse、OIKB | `1.0.0-beta.12` | 同左 | 既に完全一致。公式GitHub Releasesの最新版はbeta.12で安定版はない。registryのRCへ自動追従しない。 |
| ClickHouse | Langfuse | Compose `26.7.1`、script `25.8.28.1` | `26.7.4` | Composeとscriptの不一致を解消する。Langfuse v4は25.12以上を要求し26.4を推奨するため、26.7系は要件を満たす。 |
| RabbitMQ | Zulip | `4.2` | `4.2.9` | 公式Zulip 12.2 Composeの4.2系列を維持し、浮動minor tagをpatch固定する。 |
| Memcached | Zulip | `1.6.45-alpine` | 同左 | [公式tags](https://hub.docker.com/v2/repositories/library/memcached/tags?page_size=100&ordering=last_updated&name=1.6.)。公式Composeは浮動`memcached:alpine`だが、現行の再現可能なtagを維持する。 |
| AWS CLI | RustFS bucket init | `2.36.14` | `2.36.27` | [公式tags](https://hub.docker.com/v2/repositories/amazon/aws-cli/tags?page_size=100&ordering=last_updated&name=2.36.)。LangfuseとOIKBのbucket initを同じタグにする。 |
| Nginx | Dify | `1.31.3-alpine` | `1.31.4-alpine` | [公式tags](https://hub.docker.com/v2/repositories/library/nginx/tags?page_size=100&ordering=last_updated&name=1.31.)。 |
| Nginx Unprivileged | RPM/DEB配布 | `1.31.3-alpine` | `1.31.4-alpine` | [公式tags](https://hub.docker.com/v2/repositories/nginxinc/nginx-unprivileged/tags?page_size=100&ordering=last_updated&name=1.31.)。2サービスを同じタグにする。 |
| Redis以外の補助image | Dify | `busybox:1.38.0` | 同左 | [公式tags](https://hub.docker.com/v2/repositories/library/busybox/tags?page_size=100&ordering=last_updated&name=1.38.)。 |
| Squid | Dify | digest `sha256:6a097f…` | 同digest | [公式tags](https://hub.docker.com/v2/repositories/ubuntu/squid/tags?page_size=100&ordering=last_updated)。2026-08-21時点の`latest`と同じmanifest digest。 |
| Reprepro | registry | digest `sha256:7e4486…` | `sha256:96dbd4cdbbb5c26893a7270c8949393211aaa0ec3ff05bf1ebd22da35347e64c` | [公式tags](https://hub.docker.com/v2/repositories/eilandert/reprepro/tags?page_size=100&ordering=last_updated)。version tagがないため、最新manifest list digestを明示する。amd64限定で固定する場合はplatform manifest digestも別途固定する。 |
| createrepo_c | registry | `bullseye-0.17.0` | 同左 | [公式tags](https://hub.docker.com/v2/repositories/openitcockpit/createrepo_c/tags?page_size=100&ordering=last_updated)。 |
| Node.js | npm importer | `22-alpine` | `22.22.3-alpine` | [公式tags](https://hub.docker.com/v2/repositories/library/node/tags?page_size=100&ordering=last_updated&name=22.22.)。浮動major tagをpatch固定にする。 |

## Local buildのbase image

| build対象 | 現行base | 推奨base | 判断 |
|---|---|---|---|
| OpenClaw custom image | `ghcr.io/astral-sh/uv:0.12.0` | `0.12.5` | [uv公式release API](https://api.github.com/repos/astral-sh/uv/releases/latest)。build stageのみだが、Download script実行時の再現性に影響する。 |
| OpenClaw custom image | OpenClaw `2026.7.1-browser` | 同release系列を維持 | [OpenClaw公式release API](https://api.github.com/repos/openclaw/openclaw/releases/latest)。browser variantの存在を確認してからARGを変更する。 |
| OpenKB / LLM Wiki API | `python:3.12.11-slim-bookworm` | `3.12.14-slim-bookworm` | [公式Python tags](https://hub.docker.com/v2/repositories/library/python/tags?page_size=100&ordering=last_updated&name=3.12.)。両Dockerfileを同じtagにする。 |
| OIKB patched image | `ghcr.io/open-webui/oikb:latest` | `0.4.0` | [OIKB公式release](https://github.com/open-webui/oikb/releases/tag/v0.4.0)。実在するGHCR tagは`0.4.0`であり、浮動baseをreleaseへ固定する。 |

## majorを統一しない理由

### PostgreSQL

PostgreSQLはmajor間でdata directory形式の互換性を保証しない。major更新にはdump/restoreまたは`pg_upgrade`が必要だが、patch更新は停止、image差し替え、再起動で適用できる。このため、既存の15、16、17、18、Zulip専用14を一括して18へ変更しない。

製品側にも明確な境界がある。

- Dify 1.16.1公式ComposeはPostgreSQL 15を採用する。
- Kaneo 2.20.0公式ComposeはPostgreSQL 16を採用する。
- Zulip 12.2公式Composeは拡張入りの`zulip/zulip-postgresql:14`を採用する。
- Keycloak 26.7はPostgreSQL 14から18をサポートするため18の維持が可能である。
- Nextcloud 34はPostgreSQL 14から18をサポートし、18をrecommendedとしている。
- Langfuse v4はPostgreSQL 15以上を要件とし16を推奨する。現行18は要件を満たし、KeycloakとNextcloudとの運用タグ統一を優先できる。

### Valkey

Valkeyのmajor releaseは後方互換性を壊す可能性がある。公式versioning policyも、patchは後方互換のbug fix、majorは破壊的変更や性能特性変更を含み得ると定義する。NextcloudはValkeyをRedis互換backendとして「動作が期待される」としている一方、正式試験対象はRedisである。したがって、Nextcloudの8系をLangfuseの9系へ機械的に上げない。

### RustFS

RustFSにはまだ安定版がない。`beta.12`からRCへの境界では、mixed-version運用時の認証・lock RPC非互換が公式issueで報告されている。今回の構成はsingle-nodeだが、保存形式とrollback可否が十分文書化されていないため、公式Releaseとして公開済みの`beta.12`を両サービスで維持する。

### Zulip専用PostgreSQLとGitLab内蔵DB

ZulipのPostgreSQL imageは標準imageに必要な拡張を追加した専用品である。GitLab CE containerはPostgreSQL、RedisなどをOmnibus packageの一部として管理する。いずれもroot stack内の標準PostgreSQLタグへ置換または統一できない。

## 更新時のmigrationと互換性注意点

### 共通

- 状態を持つvolumeは更新前にbackupし、復元試験が済んだものだけを更新対象にする。
- DB、queue/cache、object storageを先に更新し、healthとデータ読出しを確認してからアプリを更新する。
- Composeと`Download-Images.ps1`を同じcommitで更新し、全profileの解決済みimage集合との差分がないことをCIで確認する。
- patch更新でもimageのentrypoint、OS variant、default pathが変わる可能性があるため、起動だけでなく既存データの読書きまで確認する。

### PostgreSQL 18

公式PostgreSQL imageは18以降、default `PGDATA`を`/var/lib/postgresql/18/docker`、volume mount pointを`/var/lib/postgresql`へ変更した。現行のKeycloak、Nextcloud、Langfuseはすでに`/var/lib/postgresql`をmountしており、18.4から18.6のpatch更新に適合する。15、16、17のサービスは従来どおり`/var/lib/postgresql/data`をmountしている。

### Langfuse 4.1.0から4.15.0

Langfuse webとworkerは必ず同じversionへ同時更新する。v4はClickHouse 25.12以上、PostgreSQL 15以上、Redis 7.0以上を必要とし、現行構成はversion要件を満たす。schema migrationは起動時に自動適用されるため、PostgreSQL、ClickHouse、RustFSのbackupを取得し、workerの既存unhealthy原因を解消してから更新する。v4のhistoric backfillを使う場合はClickHouseに概ね3倍のdisk headroomが必要である。

### Dify 1.16.1

Dify本体はすでに最新である。補助containerをレジストリの最新版へ個別更新すると、Dify releaseで検証されたCompose構成から外れる。Plugin Daemonの現行`0.6.8-local`は、commit `f28c19c`でDify本体を1.16.1へ更新した際に`0.6.3-local`から同時変更されたが、commit本文や構成内に互換性根拠は記録されていない。公式Dify 1.16.1 Composeは現在も`0.6.3-local`を指定する。このため、既存環境で使われている0.6.8を直ちにdowngradeせず暫定維持し、`0.6.10-local`への更新も保留する。次のDify releaseが新しいtagを公式に指定した時点で追随する。個別に更新する場合はplugin install、upgrade、restart、workflow実行を確認する。

### Nextcloud 34.0.3

更新前にdatabase、config、data directoryをbackupする。Nextcloudはdowngradeをサポートしない。container更新後にmaintenance mode、app互換性、`occ status`、background job、file upload/download、file lockingを確認する。

### Wiki.js 2.5.314

アプリimageは据え置きでPostgreSQL 17のpatchだけを更新する。現行稼働containerに残る旧directory・port labelは、現行Composeで再作成して解消する。ログイン、既存ページ表示、編集保存、asset取得、DB healthを確認する。

### Kaneo 2.20.0

公式ComposeはPostgreSQL 16を維持する。2.12.1から2.20.0までに複数のDB migrationを含むため、DB backup後に単独で起動し、migration完了ログ、`/api/health`、ログイン、project/taskの読書きを確認する。

### Keycloak 26.7.2

patch更新でもDB schemaが更新される可能性があり、旧serverへ戻すには旧installationとDB backupの両方が必要である。database backup後にKeycloak本体を更新し、realm import用config CLIはKeycloak 26互換tagを維持する。realm、client、login flow、token発行、HTTPS endpointを確認する。

### Zulip 12.2-0

公式Composeどおり専用PostgreSQL 14を維持する。Docker構成の推奨backup単位は、database dumpを含むZulip `/data` volume snapshotである。Zulip本体更新後にDB migration、message送受信、attachment、email、RabbitMQ、Redis、Memcachedを確認する。

### GitLab 19.2.4

GitLab 19では`19.2`がrequired upgrade stopであり、同minorの最新patchへ上げるのが公式推奨である。更新前にGitLab backupを取得し、更新後はbackground migrationが完了するまで次のminorへ進めない。Web UI、Git over SSH/HTTP、Container Registry、Runner jobを確認する。

## Download-Images.ps1の同期差分

更新実装では、少なくとも次の差分を解消する必要がある。

| 分類 | 現状 | 対応 |
|---|---|---|
| Composeと異なる | ClickHouseがscriptでは`25.8.28.1`、Composeでは`26.7.1` | 両方を`26.7.4`へ揃える。 |
| scriptに不足 | Wiki.js `2.5.314` | 追加する。 |
| scriptに不足 | PostgreSQL `17.11-alpine` | Wiki.js用として追加する。 |
| scriptに不足 | Valkey `9.1.1-alpine3.24` | Langfuse用として追加する。 |
| scriptのみ | `alpine:3.24.1` | root ComposeとLocalImagesのbuildに直接使われていないため削除する。 |
| scriptのみ | `mysql:8.4.10` | root Composeで未使用のため削除する。 |
| 廃止済み | `lscr.io/linuxserver/mariadb:11.4.12` | BookStack停止後は削除する。volumeを削除するかどうかは別判断とする。 |
| 浮動tag | `mcpo:main`、`node:22-alpine` | 安定releaseまたは完全versionへ固定する。 |
| digest更新 | Reprepro旧digest | 公式`latest`の確認済みdigestへ更新する。 |
| LocalImages | OIKBとOpenClawだけをbuild | root Composeのlocal build対象であるOpenKBとLLM Wiki APIをarchive対象に含めるか、別の配布手順を明記する。 |

## References

- [Langfuse v4 migration guide](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
- [Langfuse scaling requirements](https://langfuse.com/self-hosting/configuration/scaling)
- [Langfuse PostgreSQL requirements](https://langfuse.com/self-hosting/deployment/infrastructure/postgres)
- [Dify 1.16.1 official Docker Compose](https://github.com/langgenius/dify/blob/1.16.1/docker/docker-compose.yaml)
- [Nextcloud 34 system requirements](https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html)
- [Nextcloud memory caching](https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/caching_configuration.html)
- [Nextcloud upgrade guide](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/update.html)
- [Wiki.js 2.x requirements](https://js.wiki/get-started)
- [Kaneo v2.20.0 Compose](https://github.com/usekaneo/kaneo/blob/v2.20.0/compose.yml)
- [Kaneo changelog](https://github.com/usekaneo/kaneo/blob/v2.20.0/CHANGELOG.md)
- [Keycloak supported databases](https://www.keycloak.org/server/supported-configurations)
- [Keycloak upgrading guide](https://www.keycloak.org/docs/latest/upgrading/)
- [Zulip 12.2 Docker Compose](https://github.com/zulip/docker-zulip/blob/12.2-0/compose.yaml)
- [Zulip backup and restore](https://github.com/zulip/zulip/blob/main/docs/production/export-and-import.md)
- [GitLab upgrade paths](https://docs.gitlab.com/update/upgrade_paths/)
- [GitLab 19 upgrade notes](https://docs.gitlab.com/update/versions/gitlab_19_changes/)
- [PostgreSQL versioning policy](https://www.postgresql.org/support/versioning/)
- [PostgreSQL official container PGDATA guidance](https://hub.docker.com/_/postgres)
- [Valkey releases and versioning](https://valkey.io/topics/releases/)
- [Valkey Redis migration and compatibility](https://valkey.io/topics/migration/)
- [RustFS releases](https://github.com/RustFS/RustFS/releases)
- [RustFS mixed-version RC incompatibility report](https://github.com/rustfs/rustfs/issues/5922)
- [Docker Hub Tags API](https://docs.docker.com/docker-hub/api/latest/)
- [GitHub REST API Releases](https://docs.github.com/en/rest/releases/releases)
