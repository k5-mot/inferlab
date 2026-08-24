# XWiki Docker Compose構成調査（2026-08-24）

## 結論

新規の本番環境には、XWiki公式が新規本番導入向けに推奨しているIntermediate Long Term Support（LTS）の`xwiki:18.4.4-postgres-tomcat`を推奨する。最新機能を優先する場合は`xwiki:18.6.0-postgres-tomcat`、安定性と長期保守を最優先する場合は`xwiki:17.10.12-postgres-tomcat`が選択肢になる。`latest`、`stable-postgres-tomcat`、`lts-postgres-tomcat`などの浮動tagは、再pull時に内容が変わるため使用しない。

PostgreSQLはXWiki公式のcycle 17および18向けComposeが`postgres:18`を採用している。再現性を確保し、このrepository内のPostgreSQL 18系と揃える場合は、2026-08-24時点の同一major最新patchである`postgres:18.6-trixie`を推奨する。PostgreSQL 18ではvolumeのmount先が`/var/lib/postgresql`へ変更されているため、17以前で使われる`/var/lib/postgresql/data`と混同してはならない（MUST NOT）。

XWiki公式のPostgreSQL Compose例は、`docker-compose.yml`と`.env`を使用し、MySQL向け一般例にある`init.sql`は使用しない。DB初期化はPostgreSQL公式imageの環境変数と`POSTGRES_INITDB_ARGS`で完結する。

## 推奨イメージ

| 用途 | XWiki image | PostgreSQL image | 判定理由 |
|---|---|---|---|
| 新規本番導入 | `xwiki:18.4.4-postgres-tomcat` | `postgres:18.6-trixie` | XWiki 18.4.4は公式が新規本番導入向けに推奨するIntermediate LTS。PostgreSQLは公式Composeと同じmajorをpatchまで固定する。 |
| 安定性優先 | `xwiki:17.10.12-postgres-tomcat` | `postgres:18.6-trixie` | XWiki 17.10.12は公式が本番向けに最も安定しているとするLTS。cycle 17の公式ComposeもPostgreSQL 18を採用する。 |
| 最新機能優先 | `xwiki:18.6.0-postgres-tomcat` | `postgres:18.6-trixie` | XWiki 18.6.0は現行cycleの最新stable。公式cycle 18 Composeの既定値でもある。 |

XWikiのDocker Official Imageには、上記3版それぞれの`-postgres-tomcat`tagが存在する。`postgres-tomcat`、`stable-postgres-tomcat`、`lts-postgres-tomcat`は用途を表すaliasであり、version固定にはならない。

## 必須環境変数

### XWiki

| 変数 | 必須性 | 用途 |
|---|---|---|
| `DB_USER` | 必須 | XWikiがPostgreSQLへ接続するユーザー名。 |
| `DB_PASSWORD` | 必須 | XWikiがPostgreSQLへ接続するpassword。実値をComposeへ直接記載してはならない（MUST NOT）。 |
| `DB_DATABASE` | 必須 | XWikiが使用するdatabase名。 |
| `DB_HOST` | 必須 | PostgreSQLのCompose service名またはnetwork alias。公式imageの既定値は`db`。 |
| `DB_PORT` | 任意 | PostgreSQLのport。未指定時はJDBC driverの既定値`5432`。 |
| `JAVA_OPTS` | 任意 | JVM heapなどの調整。imageは既定で`-Xmx1024m`を保持する。 |
| `CONTEXT_PATH` | 任意 | Tomcatのcontext path。未指定時はROOTへ配置される。 |
| `JDBC_PARAMS` | 任意 | JDBC parameterを既定値から置き換える。値は`?`で始め、XML encodeする必要がある。 |

XWiki imageは`DB_USER_FILE`、`DB_PASSWORD_FILE`、`DB_DATABASE_FILE`、`DB_HOST_FILE`、`DB_PORT_FILE`、`JDBC_PARAMS_FILE`もサポートする。通常の変数と対応する`_FILE`変数を同時に指定するとentrypointがerrorにするため、どちらか一方だけを使用しなければならない（MUST）。

`XWIKI_VERSION`は公式Composeの`.env`とservice environmentに含まれるが、version固定tagから起動するために追加で必要な接続設定ではない。repositoryではimage tagを直接固定し、同じversionを二重管理しない構成が単純である。

### PostgreSQL

| 変数 | 必須性 | 用途 |
|---|---|---|
| `POSTGRES_PASSWORD` | 必須 | PostgreSQL superuserのpassword。XWikiの`DB_PASSWORD`と一致させる。 |
| `POSTGRES_USER` | 構成上必須 | XWiki用userを初期作成する。XWikiの`DB_USER`と一致させる。 |
| `POSTGRES_DB` | 構成上必須 | XWiki用databaseを初期作成する。XWikiの`DB_DATABASE`と一致させる。 |
| `POSTGRES_INITDB_ARGS` | 推奨 | 公式XWiki例は`--encoding=UTF8 --locale-provider=builtin --locale=C.UTF-8`を指定する。 |

PostgreSQL側でも`POSTGRES_PASSWORD_FILE`、`POSTGRES_USER_FILE`、`POSTGRES_DB_FILE`などのDocker secrets連携が利用できる。ただし、これらの初期化変数は空のdata directoryを初回起動するときだけ反映される。

## 必須volume

| volume | container path | 保存対象 |
|---|---|---|
| `xwiki-data` | `/usr/local/xwiki` | XWiki permanent directory。添付file、cache、Distribution Wizardの状態、永続logなどを含む。 |
| `postgres-data` | `/var/lib/postgresql` | PostgreSQL 18のdatabase cluster。 |

PostgreSQL 17以前を採用する場合のmount先は`/var/lib/postgresql/data`である。18以降ではversion固有の`PGDATA`が`/var/lib/postgresql/18/docker`となり、imageが宣言するvolume rootも`/var/lib/postgresql`へ変わった。

## 初期起動

XWiki公式ComposeはXWiki serviceへ`init: true`を設定する。これはTomcat JVMを直接PID 1にせず、LibreOfficeなどから孤児化したprocessを回収するためであり、踏襲すべきである（SHOULD）。

初回accessではDistribution Wizardが起動し、管理者作成とStandard FlavorなどのUI導入を行う。Flavorの解決とdownloadにはinternet接続が必要である。wizard完了後の状態はdatabaseとXWiki permanent directoryの両方へ保存されるため、初期化をやり直す場合は片方だけでなく両volumeを対象にする必要がある。

公式手順の起動commandは次のとおりである。

```bash
# XWikiとPostgreSQLをbackgroundで起動する。
docker compose up -d

# XWikiとPostgreSQLのcontainerが稼働していることを確認する。
docker compose ps

# 初期化進行とerrorを確認する。
docker compose logs -f web db
```

期待結果:

- PostgreSQLが接続受付可能になった後、XWikiがTomcatのport 8080で応答する。
- 初回accessでDistribution Wizardが表示される。
- wizardで管理者作成とUI導入を完了すると、次回再起動時には通常画面が表示される。

失敗判定:

- PostgreSQLがpassword、locale、volume permissionのerrorで停止する。
- XWiki logにJDBC接続errorが継続して出力される。
- 十分な待機後もHTTP応答が返らない、またはDistribution Wizardが開始しない。

## ヘルスチェック

XWiki公式Compose例にはhealthcheckがなく、短縮形の`depends_on`はDB containerの起動順だけを保証する。DBの接続受付完了を待つため、repository実装ではPostgreSQLへ`pg_isready`のhealthcheckを追加し、XWiki側の`depends_on`を`condition: service_healthy`にすることを推奨する。

```yaml
services:
  xwiki:
    depends_on:
      xwiki-db:
        condition: service_healthy
  xwiki-db:
    healthcheck:
      # PostgreSQLがXWiki用databaseへの接続を受け付けることを確認する。
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
```

XWiki imageには`curl`が含まれるため、HTTP healthcheckを追加できる。初回起動はdatabase schema作成やextension初期化に時間がかかるため、短い`start_period`は避ける。

```yaml
services:
  xwiki:
    healthcheck:
      # Tomcat上のXWiki rootがHTTP errorなしで応答することを確認する。
      test: ["CMD-SHELL", "curl --fail --silent --show-error http://localhost:8080/ >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s
```

このXWiki healthcheckと待機時間は公式Composeそのものではなく、公式imageの同梱toolとXWikiの起動特性を基にしたrepository向け推奨値である。実機で初回起動時間を計測して調整する必要がある。

## 既知の注意点

- PostgreSQLの`POSTGRES_*`と`POSTGRES_INITDB_ARGS`は空のdata directoryでのみ有効である。既存volumeを残して値だけ変更してもuser、password、database、localeは再作成されない。
- PostgreSQLのmajor versionを変更するときは、volumeを新imageへそのまま接続せず、`pg_upgrade`またはdump/restoreの移行計画が必要である。
- XWikiを完全に初期化するには、PostgreSQL volumeと`/usr/local/xwiki`のvolumeを両方初期化する。片方を残すとDistribution Wizardやextensionの状態が不整合になる可能性がある。
- 初回Distribution Wizardはextensionを取得するためinternet接続を必要とする。閉域環境ではXIP packageなどのoffline provisioningを別途設計する。
- `CONTEXT_PATH`を設定後にROOTへ戻す場合、永続化された`xwiki.cfg`の`xwiki.webapppath`も修正が必要になる場合がある。
- `JDBC_PARAMS`を設定するとimageの既定parameterを追加するのではなく置き換えるため、必要な既定値を失わないようにする。
- XWiki imageのJVM heap既定値は1 GiBである。Composeのmemory limitをそれ未満にするとOOMの危険がある。利用規模に応じて`JAVA_OPTS`とcontainer limitを同時に調整する。
- XWiki公式imageの対応architectureは`amd64`と`arm64/v8`である。
- XWikiのversion更新ではdatabaseだけでなくDistribution Wizardによるextension/UI更新が発生する。更新前に両volumeをbackupする。

## 実装時の最小構成

新規本番導入を優先する場合の実装値は次のとおりである。

| 項目 | 推奨値 |
|---|---|
| XWiki image | `xwiki:18.4.4-postgres-tomcat` |
| PostgreSQL image | `postgres:18.6-trixie` |
| XWiki port | container側`8080` |
| XWiki volume | `/usr/local/xwiki` |
| PostgreSQL volume | `/var/lib/postgresql` |
| PostgreSQL初期化 | UTF-8、builtin locale provider、`C.UTF-8` |
| 起動依存 | PostgreSQLの`service_healthy`を待つ |
| 初期UI | Distribution Wizardで導入 |

## References

- [XWiki: Required Files in Docker Compose](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/docker-compose/required-files/)
- [XWiki: Run XWiki (PostgreSQL on Tomcat) Using Docker Compose](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/docker-compose/run-xwiki-postgresql-tomcat/)
- [XWiki Docker: cycle 18 PostgreSQL Compose](https://github.com/xwiki/xwiki-docker/blob/master/18/postgres-tomcat/docker-compose.yml)
- [XWiki Docker: cycle 17 PostgreSQL Compose](https://github.com/xwiki/xwiki-docker/blob/master/17/postgres-tomcat/docker-compose.yml)
- [XWiki Docker Official Image tags](https://hub.docker.com/_/xwiki/tags)
- [XWiki: Download and recommended versions](https://www.xwiki.org/xwiki/bin/view/Download/)
- [XWiki: Environment Variables of the Docker Image](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/configuration/environment-variables/)
- [XWiki: Configuration Files in the Docker Image](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/configuration/configuration-files/)
- [XWiki: Docker Volumes Used by XWiki Containers](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/configuration/volumes/)
- [XWiki: Distribution Wizard](https://www.xwiki.org/xwiki/bin/view/Documentation/UserGuide/Features/DistributionWizard)
- [PostgreSQL Docker Official Image](https://hub.docker.com/_/postgres)
- [Docker Docs: Control startup and shutdown order in Compose](https://docs.docker.com/compose/how-tos/startup-order/)
