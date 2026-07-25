# 23-team-git

Giteaを中心にしたteam git stack。

## 構成

- Gitea
- PostgreSQL

Giteaは公式Docker imageを使用し、PostgreSQL接続は公式documentの`GITEA__database__*`環境変数方式に合わせる。

## 起動

```bash
# Gitea stackを起動する。
sudo docker compose --env-file .env --profile team-git up -d
```

期待値:

- Giteaが`http://${PUBLIC_HOST}:32300`で応答する。
- SSH clone用portとして`${GITEA_SSH_HOST_PORT:-32322}`がhostへ公開される。
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
sudo docker compose --env-file .env --profile team-git exec gitea gitea admin user create --admin --username "${GITEA_ADMIN_USER:-admin}" --password "${GITEA_ADMIN_PASSWORD:-admin}" --email "${GITEA_ADMIN_EMAIL:-admin@example.com}" --must-change-password=false --config /data/gitea/conf/app.ini
```

期待値:

- 指定したuserでGiteaへログインできる。

失敗条件:

- 同名userが既に存在する。
- Giteaのdatabase migrationが完了していない。

## References

- [Installation with Docker](https://docs.gitea.com/installation/install-with-docker)
- [Configuration Cheat Sheet](https://docs.gitea.com/administration/config-cheat-sheet)

