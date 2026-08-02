# 31-bookstack

BookStackとMariaDBをまとめたWiki stack。Keycloak OIDC loginを使う。

## 起動時初期化

BookStackのLinuxServer imageは`/custom-cont-init.d`を実行する。Composeでは、先に`bookstack-custom-init`がCompose内のinit commandでrepository内の`custom-cont-init.d`を名前付きvolumeへコピーし、`bookstack`がそのvolumeを読み込む。

同梱している初期化scriptは次の通り。

| Script | 初期化内容 |
| --- | --- |
| `10-keycloak-ca.sh` | Keycloak HTTPS issuer用の自己署名証明書をcontainerのtrust storeへ追加する。 |
| `20-oidc-roles.sh` | 既定のBookStack管理者をKeycloakの`admin` userへ紐付け、Keycloakの`admins`/`users` groupをBookStack roleへ対応付け、OIDC userの初期roleをEditorへ寄せる。 |

BookStackはOIDC userの対応付けにExternal Authentication IDを使う。このstackでは`OIDC_EXTERNAL_ID_CLAIM=preferred_username`を設定し、初期管理者`admin@admin.com`のExternal Authentication IDを`admin`へ更新する。これにより、初期状態のBookStack管理者とKeycloakの`admin` userが同じmail addressを持っていても、OIDC loginで衝突しない。

## 事前準備

BookStackはHTTPS issuerを要求するため、Keycloak証明書が必要になる。

```bash
# Keycloak HTTPS issuer用の自己署名証明書を生成する。
PUBLIC_HOST="${PUBLIC_HOST:-localhost}" ./01-keycloak/keycloak/generate-certs.sh
```

期待結果:

- `01-keycloak/keycloak/certs/keycloak.crt`が存在する。
- `bookstack` containerが証明書を読み込める。

失敗条件:

- 証明書が無く、OIDC discoveryでTLS検証に失敗する。
- Keycloakのissuer URLと証明書SANが一致しない。

## 起動

```bash
# BookStack stackを起動する。
sudo docker compose --env-file .env --profile bookstack up -d
```

期待結果:

- `bookstack-custom-init`が正常終了する。
- `bookstack-mariadb`がhealthyになる。
- `bookstack`が`http://${PUBLIC_HOST}:${BOOKSTACK_HOST_PORT:-33100}`で応答する。
- Keycloak login後、`admins`または`users` groupに応じたBookStack roleが付与される。

失敗条件:

- `bookstack-custom-init`がcustom init scriptをvolumeへコピーできない。
- MariaDB schema初期化前にrole更新SQLが失敗する。
- Keycloak証明書が信頼されずOIDC discoveryに失敗する。

## 確認手順

```bash
# BookStack profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile bookstack ps

# BookStack login画面の応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:${BOOKSTACK_HOST_PORT:-33100}/login" >/dev/null
```

期待結果:

- `bookstack`がhealthyになる。
- login画面からKeycloak OIDC loginへ遷移できる。

失敗条件:

- `bookstack` logにOIDC discoveryまたはcertificate verify失敗が出る。
- `20-oidc-roles.sh`がMariaDB接続失敗で止まる。

## 再初期化

BookStackを初期化し直す場合は、BookStackとMariaDBのvolumeを削除する。既存Wiki内容を失う。

```bash
# BookStack stackを停止する。
sudo docker compose --env-file .env --profile bookstack down

# BookStack関連の永続volumeを削除する。
sudo docker volume rm "${STACK_NAME:-inferlab}_bookstack-config" "${STACK_NAME:-inferlab}_bookstack-custom-cont-init" "${STACK_NAME:-inferlab}_bookstack-mariadb-config"

# BookStack stackを再作成する。
sudo docker compose --env-file .env --profile bookstack up -d
```

期待結果:

- custom init scriptが再コピーされる。
- BookStack schemaとrole設定が再作成される。

失敗条件:

- volumeが使用中で削除できない。
- Keycloak client secretがBookStack側と一致しない。

## References

- [BookStack: OpenID Connect Authentication](https://www.bookstackapp.com/docs/admin/oidc-auth/)
