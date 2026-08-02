# 30-nextcloud

Nextcloud、PostgreSQL、Valkeyをまとめたfile storage stack。

## 起動時初期化

Nextcloud公式entrypointの`before-starting` hookを使い、既存volumeで再起動した場合も設定を再適用する。

| Hook | 初期化内容 |
| --- | --- |
| `05-configure-trusted-domains.sh` | `trusted_domains`と`allow_local_remote_servers`をCompose環境変数から再設定する。 |
| `06-install-user-oidc.sh` | `user_oidc` appを事前取得archiveまたは公式releaseから復元し、checksum確認後に有効化する。 |
| `10-disable-external-checks.sh` | update checker、internet connection check、recommendations系appを無効化する。 |
| `20-configure-oidc-logout.sh` | Keycloak OIDC provider、logout endpoint、claim mapping、group provisioningを設定する。 |
| `25-configure-oikb-share.sh` | `admin` userの`/oikb` folderを作成し、`users` groupへ共有する。 |
| `30-configure-openmetrics.sh` | Prometheus scrape用の`openmetrics_allowed_clients`を設定する。 |

## 起動

```bash
# Nextcloud stackを起動する。
sudo docker compose --env-file .env --profile nextcloud up -d
```

期待結果:

- `nextcloud-postgres`と`nextcloud-valkey`がhealthyになる。
- `nextcloud`が`http://${PUBLIC_HOST}:33000`で応答する。
- `user_oidc` appが有効化される。
- `/oikb` folderが作成され、`users` groupへ共有される。

失敗条件:

- `user_oidc` archiveのchecksumが一致しない。
- online環境で`user_oidc` release archiveを取得できない。
- Keycloak discovery URLへ到達できない。
- OIKB共有ownerの`admin` userが存在しない。

## 確認手順

```bash
# Nextcloud profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile nextcloud ps

# Nextcloud status endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:33000/status.php" >/dev/null

# user_oidc appが有効化されていることを確認する。
sudo docker compose --env-file .env --profile nextcloud exec nextcloud php occ app:list | grep -A 20 Enabled | grep user_oidc
```

期待結果:

- `nextcloud`がhealthyになる。
- `user_oidc`がEnabledに表示される。
- Keycloak loginボタンまたはOIDC login flowが利用できる。

失敗条件:

- Nextcloud hookが途中で失敗してcontainerが再起動する。
- `occ user_oidc:provider`が失敗する。
- OIKB用共有folderが作成されない。

## airgap環境

airgap環境では、事前に`30-nextcloud/nextcloud/apps/user_oidc-v8.10.1.tar.gz`を配置する。詳細は[docs/manual/DOWNLOAD.md](../docs/manual/DOWNLOAD.md)を参照する。

## 再初期化

Nextcloud本体を初期状態へ戻す場合は、NextcloudとPostgreSQLのvolumeを削除する。保存済みfile、user、app設定を失う。

```bash
# Nextcloud stackを停止する。
sudo docker compose --env-file .env --profile nextcloud down

# Nextcloud関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME:-inferlab}_nextcloud" "${STACK_NAME:-inferlab}_nextcloud-postgres"

# Nextcloud stackを再作成する。
sudo docker compose --env-file .env --profile nextcloud up -d
```

期待結果:

- Nextcloud初期セットアップとhookが再実行される。
- `admin` userと`/oikb`共有folderが再作成される。

失敗条件:

- volumeが使用中で削除できない。
- `user_oidc` app archiveが無く、外部取得もできない。
