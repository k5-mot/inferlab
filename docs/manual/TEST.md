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
| `compose-smoke-dify-postgres-init` | 2 | 新規PostgreSQLのhealthcheck完了後に`dify_plugin` databaseを作成できること | 作成済みdatabaseに対する再実行、Dify API、worker、Web UI、plugin daemonの起動とmigration |
| `compose-smoke-pypiserver-readonly` | 2 | 非rootのPyPIserverがread-onlyのpackage directoryを配信し、healthyになること | wheelの完全性、plugin daemonによるinstall、外部通信の有無 |
| `compose-smoke-oikb-bucket-init` | 2 | 新規RustFSのhealthcheck完了後に`oikb-bucket`を作成できること | 作成済みbucketに対する再実行、Open WebUI、OIKB、Nextcloudの起動と同期 |
| `compose-smoke-ragflow-bucket-init` | 2 | 新規RustFSのhealthcheck完了後に`ragflow-bucket`を作成できること | 作成済みbucketに対する再実行、RAGFlow、Elasticsearch、MySQL、Valkeyの起動と文書取込 |
| `compose-smoke-langfuse-bucket-init` | 2 | 新規RustFSのhealthcheck完了後に`langfuse-bucket`を作成できること | 作成済みbucketに対する再実行、Langfuse Web、worker、ClickHouse、PostgreSQLの起動とevent取込 |

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
STACK_NAME=static-validation tests/verify-init-static.sh
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
# Difyのplugin用PostgreSQL database初期化だけを検証する。
tests/verify-compose-smoke.sh dify-postgres-init

# read-onlyのpackage directoryでPyPIserverの起動を検証する。
tests/verify-compose-smoke.sh pypiserver-readonly

# OIKB用RustFS bucket初期化だけを検証する。
tests/verify-compose-smoke.sh oikb-bucket-init

# RAGFlow用RustFS bucket初期化だけを検証する。
tests/verify-compose-smoke.sh ragflow-bucket-init

# Langfuse用RustFS bucket初期化だけを検証する。
tests/verify-compose-smoke.sh langfuse-bucket-init

```

pre-commitから個別に実行する場合は、対応するhook IDを指定する。

```bash
# DifyのPostgreSQL init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-dify-postgres-init --hook-stage manual

# PyPIserverのread-only package配信だけをmanual stageで実行する。
pre-commit run compose-smoke-pypiserver-readonly --hook-stage manual

# OIKBのbucket init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-oikb-bucket-init --hook-stage manual

# RAGFlowのbucket init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-ragflow-bucket-init --hook-stage manual

# Langfuseのbucket init smokeだけをmanual stageで実行する。
pre-commit run compose-smoke-langfuse-bucket-init --hook-stage manual

```

期待結果:

- 対象のinit serviceが`exited (0)`になる。
- PyPIserverの検証では、read-onlyのpackage directoryを維持したままserviceが`healthy`になる。
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

Playwright E2Eはブラウザ、Keycloak、対象serviceと関連databaseを使うため、通常のcommit前hookには含めない。必要なcaseをlocalで明示的に実行する。

### 前提

- Docker daemon、Docker Compose plugin、Node.js、npm、Python 3、OpenSSLが必要。
- 対象caseに必要なprofileだけを一時Compose projectとして起動する。
- PlaywrightとChromiumはrepository外の一時cacheへ導入する。

### 実行手順

```bash
# 利用できるPlaywright smoke caseを一覧表示する。
tests/e2e/run-playwright-smoke.sh --list

# NextcloudのOIDC認証とfolder作成を検証する。
tests/e2e/run-playwright-smoke.sh nextcloud

# 実装済みのPlaywright smoke caseを順番にすべて実行する。
tests/e2e/run-playwright-smoke.sh all
```

期待結果:

- Keycloak、対象service、その関連databaseだけが起動する。
- 対象serviceのOIDC loginからKeycloak user `admin`で認証できる。
- caseごとの基本操作で検証用dataを作成できる。
- 検証後、一時Compose projectのcontainer、volume、networkと一時証明書が削除される。

失敗条件:

- 必須commandのいずれかを利用できない。
- Keycloakまたは対象serviceが`healthy`にならない。
- OIDC認証またはcase固有の基本操作に失敗する。
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
