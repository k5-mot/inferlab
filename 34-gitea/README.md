# 34-gitea

Giteaを中心にしたteam git stack。

## 構成

- Gitea
- PostgreSQL

Giteaは公式Docker imageを使用し、PostgreSQL接続は公式documentの`GITEA__database__*`環境変数方式に合わせる。

## 起動時初期化

`gitea`本体がhealthyになった後、`gitea-keycloak-init`が`init/sync-keycloak-oauth.sh`でKeycloak OAuth sourceを作成または更新する。

初期化処理は次の通り。

1. `/data/gitea/conf/app.ini`を使って既存auth sourceを確認する。
2. `keycloak`という名前のauth sourceがあれば`update-oauth`で更新する。
3. 無ければ`add-oauth`でOpenID Connect auth sourceを追加する。
4. `openid`、`email`、`profile` scopeと`groups` claimを設定する。

この処理はGitea管理者userの作成とは別である。管理者userは手動で作成する。

## 起動

```bash
# Gitea stackを起動する。
sudo docker compose --env-file .env --profile gitea up -d
```

期待値:

- Giteaが`http://${PUBLIC_HOST}:33400`で応答する。
- SSH clone用portとして`${GITEA_SSH_HOST_PORT:-33422}`がhostへ公開される。
- PostgreSQL containerがhealthyになる。

失敗条件:

- `docker compose config --quiet`が失敗する。
- GiteaまたはPostgreSQL containerがunhealthyになる。
- 初期起動後に`/data/gitea/conf/app.ini`が生成されない。

## Metrics

GiteaのPrometheus endpointを有効化する。

- `GITEA__metrics__ENABLED=true`
- label別issue metricsとrepository別issue metricsはcardinalityを増やすため無効化する。

Prometheus側のscrape対象は`50-o11y/prometheus/prometheus.yaml`の`gitea:3000`で定義済み。

## 初期管理者

初期管理者は、初回起動後にGitea CLIで作成する。

```bash
# Gitea管理者userを作成する。
sudo docker compose --env-file .env --profile gitea exec gitea gitea admin user create --admin --username "${GITEA_ADMIN_USER:-admin}" --password "${GITEA_ADMIN_PASSWORD:-admin}" --email "${GITEA_ADMIN_EMAIL:-admin@example.com}" --must-change-password=false --config /data/gitea/conf/app.ini
```

期待値:

- 指定したuserでGiteaへログインできる。

失敗条件:

- 同名userが既に存在する。
- Giteaのdatabase migrationが完了していない。

## Keycloak連携の確認

```bash
# Keycloak OAuth sourceが登録されていることを確認する。
sudo docker compose --env-file .env --profile gitea exec gitea gitea admin auth list --config /data/gitea/conf/app.ini
```

期待値:

- `keycloak` auth sourceが表示される。
- Gitea login画面にKeycloak loginが表示される。

失敗条件:

- `gitea-keycloak-init`が`exited (0)`にならない。
- `GITEA_OIDC_CLIENT_SECRET`がKeycloak側client secretと一致しない。
- discovery URLへ接続できない。

## References

- [Installation with Docker](https://docs.gitea.com/installation/install-with-docker)
- [Configuration Cheat Sheet](https://docs.gitea.com/administration/config-cheat-sheet)
