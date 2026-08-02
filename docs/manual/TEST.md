# テスト

## テストレベル

テストは実行コストと確認範囲に応じて、次の3段階に分ける。

| レベル | 種別 | 実行タイミング | 到達範囲 |
| --- | --- | --- | --- |
| 1 | 静的検証 | commit前、対象branchへのpush、Pull Request | 構文とDocker Compose設定の解決 |
| 2 | Compose smoke | 手動、対象branchへのpush、Pull Request | 初期化serviceと最小限の依存serviceの実行 |
| 3 | Playwright E2E | 手動 | 認証を含むブラウザ上の主要操作 |

上位レベルは下位レベルの全項目を包含しない。たとえばPlaywright E2Eを実行しても、すべてのshell scriptの構文を確認したことにはならない。

## テスト一覧と保証範囲

| テスト | レベル | 確認する範囲 | 確認しない範囲 |
| --- | --- | --- | --- |
| `static-validation` | 1 | 追跡済みshell、Python、JavaScriptの構文と、root Composeおよび主要profileの設定解決 | container起動、初期化処理の実行、外部serviceとの通信、画面操作 |
| `compose-smoke-bookstack-init` | 2 | `bookstack-custom-init`によるinit scriptのvolumeコピー、所有者、実行権限の設定 | MariaDBとBookStack本体の起動、script内容の実行、OIDC認証 |
| `compose-smoke-dify-postgres-init` | 2 | 新規PostgreSQLのhealthcheck完了後に`dify_plugin` databaseを作成できること | 作成済みdatabaseに対する再実行、Dify API、worker、Web UI、plugin daemonの起動とmigration |
| `compose-smoke-oikb-bucket-init` | 2 | 新規RustFSのhealthcheck完了後に`oikb-bucket`を作成できること | 作成済みbucketに対する再実行、Open WebUI、OIKB、Nextcloudの起動と同期 |
| `compose-smoke-langfuse-bucket-init` | 2 | 新規RustFSのhealthcheck完了後に`langfuse-bucket`を作成できること | 作成済みbucketに対する再実行、Langfuse Web、worker、ClickHouse、PostgreSQLの起動とevent取込 |
| `compose-smoke-gitea-keycloak-init` | 2 | 一時OIDC discovery endpointを使い、GiteaへKeycloak OAuth sourceを新規追加できること | 登録済みsourceの更新、実Keycloakとの認証、repository操作、SSH接続 |
| `playwright-smoke-bookstack` | 3 | KeycloakとBookStackを起動し、OIDC認証後に新規Bookを1件作成できること | Book更新・削除、権限差、添付file、全文検索、他serviceの操作 |

## Level 1: 静的検証

### 前提

- `pre-commit`、Bash、Python 3、Docker Compose pluginが必要。
- JavaScript構文検証にはNode.jsを使用する。Node.jsがない環境ではJavaScript構文検証だけをskipする。
- containerは起動しない。

### pre-commit hookの登録手順

`pre-commit install`はcloneした作業treeごとに1回実行する。`.pre-commit-config.yaml`はGitで共有されるが、`.git/hooks/pre-commit`は各clone固有でありGit管理されない。

```bash
# pre-commit hookを現在のrepositoryへ登録する。
pre-commit install

# Git hookが作成され、実行可能になっていることを確認する。
test -x .git/hooks/pre-commit

# hook経由で静的検証が発火することを確認する。
.git/hooks/pre-commit
```

期待結果:

- `pre-commit installed at .git/hooks/pre-commit`と表示される。
- `.git/hooks/pre-commit`が存在し、実行権限を持つ。
- hook実行時に`Static validation`が`Passed`になる。

失敗条件:

- `pre-commit` commandが見つからない。
- `.git/hooks/pre-commit`が存在しない、または実行権限を持たない。
- hook実行時に`Static validation`が実行されない、または失敗する。

### 実行手順

```bash
# commit前と同じ静的検証をすべての追跡fileに対して実行する。
pre-commit run --all-files

# pre-commitを介さず静的検証scriptを直接実行する。
script/verify-init-static.sh
```

期待結果:

- 追跡済みshell scriptが`bash -n`を通過する。
- 追跡済みPython scriptが`python3 -m py_compile`を通過する。
- Node.jsがある場合、追跡済みJavaScript fileが`node --check`を通過する。
- root Composeと主要profileの`docker compose config`が解決できる。

失敗条件:

- 対象scriptに構文errorがある。
- Composeのinclude、profile、変数展開、service参照を解決できない。
- Docker Compose pluginを利用できない。

## Level 2: Compose smoke検証

Compose smokeは初期化対象ごとに必要なserviceだけを起動する。通常のcommit前hookには含めず、pre-commitの`manual` stageとGitHub Actionsで実行する。

### 実行手順

```bash
# BookStackのinit script配置処理だけを検証する。
script/verify-compose-smoke.sh bookstack-init

# Difyのplugin用PostgreSQL database初期化だけを検証する。
script/verify-compose-smoke.sh dify-postgres-init

# OIKB用RustFS bucket初期化だけを検証する。
script/verify-compose-smoke.sh oikb-bucket-init

# Langfuse用RustFS bucket初期化だけを検証する。
script/verify-compose-smoke.sh langfuse-bucket-init

# GiteaのKeycloak OAuth source同期だけを検証する。
script/verify-compose-smoke.sh gitea-keycloak-init
```

pre-commitから個別に実行する場合は、対応するhook IDを指定する。

```bash
# BookStackのinit smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-bookstack-init --hook-stage manual

# DifyのPostgreSQL init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-dify-postgres-init --hook-stage manual

# OIKBのbucket init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-oikb-bucket-init --hook-stage manual

# Langfuseのbucket init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-langfuse-bucket-init --hook-stage manual

# GiteaのKeycloak連携init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-gitea-keycloak-init --hook-stage manual
```

期待結果:

- 対象のinit serviceが`exited (0)`になる。
- 依存serviceが必要な場合だけ起動する。
- 検証終了後、一時Compose projectのcontainer、volume、networkが削除される。

失敗条件:

- Docker daemonまたはDocker Compose pluginを利用できない。
- 依存serviceが`healthy`にならない。
- init serviceが非0で終了する。
- cleanup後もテスト用Compose resourceが残る。

### ロールバック

通常は終了時のcleanupが自動実行される。中断などでresourceが残った場合は、テスト出力に表示された`STACK_NAME`を確認し、そのprojectだけを削除する。

```bash
# STACK_NAMEを実際のテスト用project名に置き換え、残存resourceだけを削除する。
STACK_NAME=test-project-name docker compose down --volumes --remove-orphans
```

期待結果:

- 指定したテスト用projectのcontainer、volume、networkが削除される。

失敗条件:

- `STACK_NAME`に通常運用中のproject名を指定している。
- Docker daemonへ接続できずresourceを削除できない。

## Level 3: Playwright E2E検証

Playwright E2Eはブラウザ、Keycloak、BookStackと関連databaseを使うため、通常のcommit前hookには含めない。pre-commitの`manual` stage、またはGitHub Actionsの`workflow_dispatch`から明示的に実行する。

### 前提

- Docker daemon、Docker Compose plugin、Node.js、npm、Python 3、OpenSSLが必要。
- `keycloak`と`bookstack` profileだけを一時Compose projectとして起動する。
- PlaywrightとChromiumはrepository外の一時cacheへ導入する。

### 実行手順

```bash
# KeycloakとBookStackを起動し、OIDC認証後に新規Bookを作成する。
tests/e2e/run-playwright-smoke.sh bookstack

# 同じBookStack E2Eをpre-commitのmanual stage経由で実行する。
pre-commit run playwright-smoke-bookstack --hook-stage manual
```

期待結果:

- Keycloak、Keycloak HTTPS、BookStack、関連databaseだけが起動する。
- BookStackのOIDC loginからKeycloak user `admin`で認証できる。
- BookStackに`Codex Smoke Book ...`という検証用Bookを作成できる。
- 検証後、一時Compose projectのcontainer、volume、networkと一時証明書が削除される。

失敗条件:

- 必須commandのいずれかを利用できない。
- KeycloakまたはBookStackが`healthy`にならない。
- OIDC認証またはBookStackの新規Book作成に失敗する。
- cleanup後もテスト用Compose resourceまたは一時証明書が残る。

失敗時は調査用のscreenshotとHTMLを`tests/e2e/artifacts/`へ保存する。このdirectoryはGit管理対象外である。

### ロールバック

通常は終了時のcleanupが自動実行される。中断などでresourceが残った場合は、実行時の`STACK_NAME`を使って対象projectだけを削除する。

```bash
# STACK_NAMEを実際のE2E用project名に置き換え、残存resourceだけを削除する。
STACK_NAME=e2e-project-name docker compose down --volumes --remove-orphans
```

期待結果:

- 指定したE2E用projectのcontainer、volume、networkが削除される。

失敗条件:

- `STACK_NAME`に通常運用中のproject名を指定している。
- Docker daemonへ接続できずresourceを削除できない。

## GitHub Actionsでの実行範囲

| Job | Trigger | 実行内容 |
| --- | --- | --- |
| `static` | `main`・`develop`へのpush、Pull Request、手動実行 | Level 1を実行する |
| `compose-smoke` | `main`・`develop`へのpush、Pull Request、手動実行 | Level 2の5ケースをmatrixで実行する |
| `playwright-e2e` | 手動実行のみ | Level 3のBookStackケースを実行する |
