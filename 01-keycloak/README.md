# 01-keycloak

Keycloakを中心にした認証stack。HTTP公開用の`keycloak`と、HTTPS issuerを必要とするOIDC client向けの`keycloak-https`を同じPostgreSQLへ接続する。

## 起動時初期化

`keycloak` serviceはKeycloak標準の`start --import-realm`で最小realmを作成し、`keycloak-config` serviceが`keycloak/config.yaml`を使ってrealm user、group、OIDC clientを同期する。

初期化処理は次の順で実行される。

1. `keycloak`が`keycloak/bootstrap-realm.json`を`/opt/keycloak/data/import/`へmountする。
2. `keycloak`が`start --import-realm`で`prod` realmを作成する。
3. `keycloak-config`がKeycloak Admin APIへ接続できるまで待機する。
4. `keycloak-config`が`keycloak/config.yaml`を適用し、realm user、group、OIDC clientを同期する。
5. `keycloak-config`が正常終了した後、`keycloak-https`を起動する。

`keycloak-https`は同じDBを参照し、`keycloak/certs/keycloak.crt`と`keycloak/certs/keycloak.key`を使ってHTTPS issuerを提供する。ZulipはHTTPS issuerを使うため、この証明書が必要になる。

## 事前準備

自己署名証明書が無い場合は生成する。

```bash
# Keycloak HTTPS issuer用の自己署名証明書を生成する。
PUBLIC_HOST="${PUBLIC_HOST:-localhost}" ./01-keycloak/keycloak/generate-certs.sh
```

期待結果:

- `01-keycloak/keycloak/certs/keycloak.crt`が作成される。
- `01-keycloak/keycloak/certs/keycloak.key`が作成される。
- 秘密鍵はrepositoryへ保存されない。

失敗条件:

- `openssl`が見つからない。
- `PUBLIC_HOST`に実際のアクセス元と異なるhost名を指定している。

## 起動

```bash
# Keycloak stackを起動する。
sudo docker compose --env-file .env --profile keycloak up -d
```

期待結果:

- `keycloak-postgres`がhealthyになる。
- `keycloak`が`http://${PUBLIC_HOST}:30001`で応答する。
- `keycloak-https`が`https://${PUBLIC_HOST}:30002`で応答する。
- `prod` realmが作成される。
- Open WebUI、Nextcloud、Langfuse、Leantime、Kaneo、Zulip、GitLab、Grafana向けOIDC clientが同期される。

失敗条件:

- `keycloak-config`が正常終了しない。
- `keycloak-https`が証明書を読み込めずに起動しない。
- 既存realmのclient secretが期待値と一致しない。

## 確認手順

```bash
# Keycloak containerの状態を確認する。
sudo docker compose --env-file .env --profile keycloak ps

# realmのOpenID Provider Configurationを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:30001/realms/prod/.well-known/openid-configuration" >/dev/null

# HTTPS issuerのTCP応答を確認する。
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"30002"
```

期待結果:

- `keycloak`、`keycloak-https`、`keycloak-postgres`が`running`または`healthy`になる。
- OpenID Provider Configurationの取得が成功する。
- HTTPS issuerの公開portへ接続できる。

失敗条件:

- `keycloak-postgres`がunhealthyになる。
- realm discovery endpointが404または5xxを返す。
- HTTPS issuerのportへ接続できない。

## 再初期化

realm importやclient同期を最初からやり直す場合は、Keycloakの永続volumeを削除してから再起動する。既存user、client、sessionを失うため、必要な場合だけ実行する。

```bash
# Keycloak stackを停止する。
sudo docker compose --env-file .env --profile keycloak down

# Keycloak PostgreSQLの永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_keycloak_postgres_data"

# Keycloak stackを再作成する。
sudo docker compose --env-file .env --profile keycloak up -d
```

期待結果:

- PostgreSQL volumeが空の状態で再作成される。
- realm importと`keycloak-config`による設定同期が再実行される。

失敗条件:

- volumeが使用中で削除できない。
- `.env`のclient secretと各client stack側のsecretが一致しない。
