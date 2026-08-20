# 35-gitlab

GitLab CEとGitLab Runnerを提供するprofile。

## 構成

- `gitlab`: GitLab CE本体。Omnibus設定は`gitlab/omnibus_config.rb`から読み込む。
- `gitlab-runner-register`: `GITLAB_RUNNER_TOKEN`が設定されている場合だけrunnerを登録する。
- `gitlab-runner`: 登録済み設定を使ってCI jobを実行する。

## 起動手順

```bash
# GitLab profileだけを起動する。
sudo docker compose --env-file .env --profile gitlab up -d
```

期待結果:

- GitLabが`http://${PUBLIC_HOST}:33500`で応答する。
- GitLab Service Pingは送信されない。
- `GITLAB_RUNNER_TOKEN`が空の場合、runner登録はskipされ、runner本体は未登録状態で起動する。

失敗条件:

- `gitlab`が`healthy`にならない。
- Keycloakの`gitlab` client secretと`GITLAB_OIDC_CLIENT_SECRET`が一致しない。
- runner登録が必要なのに`GITLAB_RUNNER_TOKEN`が空である。

## Runner登録

GitLab UIでrunner authentication tokenを発行し、`.env`へ設定してからprofileを再起動する。

```bash
# GitLab Runner登録を再実行する。
sudo docker compose --env-file .env --profile gitlab up -d --force-recreate gitlab-runner-register gitlab-runner
```

## References

- [Install GitLab in a Docker container](https://docs.gitlab.com/install/docker/installation/)
- [Configure GitLab running in a Docker container](https://docs.gitlab.com/install/docker/configuration/)
- [Use OpenID Connect as an authentication provider](https://docs.gitlab.com/administration/auth/oidc/)
- [Run GitLab Runner in a container](https://docs.gitlab.com/runner/install/docker/)
- [Usage statistics](https://docs.gitlab.com/administration/settings/usage_statistics/)
