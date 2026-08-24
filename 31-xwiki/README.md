# 31-xwiki

XWikiとPostgreSQLを起動するWiki stack。

## 構成

- `xwiki`: XWiki 18.4.4 Intermediate Long Term Support（LTS）のPostgreSQL/Tomcat image。
- `xwiki-postgres`: XWikiの設定、page、attachment metadataを保持するPostgreSQL 18。
- `xwiki-data`: XWikiの永続directoryを保持するvolume。
- `xwiki-postgres-data`: PostgreSQL clusterを保持するvolume。

XWikiのOIDC Authenticator 2.25.4をroot namespaceへ導入し、Keycloak `prod` realmの`xwiki` confidential clientと連携する。初期provisioning中は標準認証を使用し、extension導入後に`.env`の`XWIKI_AUTHCLASS`でOIDCへ切り替える。

## 起動

```bash
# XWikiとPostgreSQLを起動する。
sudo docker compose --env-file .env --profile xwiki up -d

# 初回起動の状態を確認する。
sudo docker compose --env-file .env --profile xwiki ps

# XWikiのHTTP endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:33100/" >/dev/null
```

期待結果:

- `xwiki-postgres`と`xwiki`がhealthyになる。
- `http://${PUBLIC_HOST}:33100`にXWikiのDistribution Wizardまたはhome pageが表示される。
- container再作成後もXWikiとPostgreSQLのdataが保持される。

失敗条件:

- `xwiki-postgres`がhealthyにならない。
- `xwiki`のlogにdatabase接続失敗が記録される。
- 初回起動から15分経過してもXWikiがhealthyにならない。

## credential設定

`.env`へ少なくとも次の値を設定する。repositoryへ実secretをcommitしてはならない（MUST NOT）。

```dotenv
XWIKI_DB_PASSWORD=change-me
XWIKI_SUPERADMIN_PASSWORD=change-me
XWIKI_LOCAL_ADMIN_PASSWORD=change-me
XWIKI_OIDC_CLIENT_SECRET=change-me
```

`XWIKI_OIDC_CLIENT_SECRET`はKeycloakとXWikiで同じ値を使用する。`XWIKI_SUPERADMIN_PASSWORD`は初期provisioningと障害復旧専用であり、通常loginには使用しない。

## 初期provisioning

初回起動時は`.env`から`XWIKI_AUTHCLASS`を外し、標準認証で起動する。Standard FlavorとOIDC Authenticatorの取得にはinternet接続が必要である。

```bash
# Standard Flavorをmain wikiへ同期installする。
curl --fail-with-body --user "superadmin:${XWIKI_SUPERADMIN_PASSWORD}" \
  --request PUT --header "Content-Type: application/xml" \
  "http://localhost:33100/rest/jobs?jobType=install&async=false" \
  --upload-file 31-xwiki/provision/standard-flavor.xml

# OIDC Authenticator 2.25.4をroot namespaceへ同期installする。
curl --fail-with-body --user "superadmin:${XWIKI_SUPERADMIN_PASSWORD}" \
  --request PUT --header "Content-Type: application/xml" \
  "http://localhost:33100/rest/jobs?jobType=install&async=false" \
  --upload-file 31-xwiki/provision/oidc-authenticator.xml

# Standard FlavorのXAR author用local管理者pageを作成する。
curl --fail-with-body --user "superadmin:${XWIKI_SUPERADMIN_PASSWORD}" \
  --request PUT --header "Content-Type: application/xml" \
  "http://localhost:33100/rest/wikis/xwiki/spaces/XWiki/pages/Admin" \
  --data-binary @31-xwiki/provision/standard-flavor-admin-page.xml

# form送信に必要なCSRF tokenを取得する。
XWIKI_FORM_TOKEN="$(curl --silent --show-error --dump-header - --output /dev/null \
  --user "superadmin:${XWIKI_SUPERADMIN_PASSWORD}" http://localhost:33100/rest/wikis \
  | sed -n 's/^[Xx][Ww]iki-[Ff]orm-[Tt]oken:[[:space:]]*//p' | tr -d '\r')"

# 復旧用local管理者objectを作成する。
curl --fail-with-body --user "superadmin:${XWIKI_SUPERADMIN_PASSWORD}" \
  --request POST --header "Content-Type: application/x-www-form-urlencoded" \
  --header "XWiki-Form-Token: ${XWIKI_FORM_TOKEN}" \
  --data-urlencode "className=XWiki.XWikiUsers" \
  --data-urlencode "property#first_name=Local" \
  --data-urlencode "property#last_name=Administrator" \
  --data-urlencode "property#active=1" \
  --data-urlencode "property#password=${XWIKI_LOCAL_ADMIN_PASSWORD}" \
  "http://localhost:33100/rest/wikis/xwiki/spaces/XWiki/pages/Admin/objects"

# Standard FlavorのXAR authorとlocal管理者へ管理権限を付与する。
curl --fail-with-body --user "superadmin:${XWIKI_SUPERADMIN_PASSWORD}" \
  --request POST --header "Content-Type: application/xml" \
  "http://localhost:33100/rest/wikis/xwiki/spaces/XWiki/pages/XWikiAdminGroup/objects" \
  --data-binary @31-xwiki/provision/standard-flavor-author.xml
```

期待結果:

- 2つのinstall jobがHTTP 200と`state=FINISHED`を返す。
- local管理者pageとobjectの作成がHTTP 201を返す。
- `http://localhost:33100/bin/view/Main/`がHTTP 200を返す。

失敗条件:

- install jobがHTTP 500を返す、またはjob logの最終stateが`FINISHED`でない。
- extension repositoryへ接続できず依存関係を解決できない。
- OIDC AuthenticatorのJARが`xwiki-data` volumeへ保存されない。

## Keycloak連携の有効化

provisioning完了後、`.env`へ次を追加する。

```dotenv
XWIKI_AUTHCLASS=org.xwiki.contrib.oidc.auth.OIDCAuthServiceImpl
```

```bash
# Keycloakへxwiki clientとredirect URIを適用する。
sudo docker compose --env-file .env --profile keycloak up --force-recreate keycloak-config

# OIDC設定を反映するためXWikiを再作成する。
sudo docker compose --env-file .env --profile xwiki up -d xwiki

# login endpointがKeycloakへredirectすることを確認する。
curl --silent --show-error --output /dev/null --dump-header - \
  http://localhost:33100/bin/login/XWiki/XWikiLogin
```

期待結果:

- login endpointがKeycloakの`prod` realmへHTTP 302でredirectする。
- authorization requestの`client_id`が`xwiki`になる。
- `redirect_uri`が`http://localhost:33100/oidc/authenticator/callback`になる。
- Keycloakの`admins` userでloginすると`XWiki.admin` profileが作成され、`XWikiAdminGroup`へ同期される。

失敗条件:

- Keycloakが`invalid_redirect_uri`または`invalid_client`を返す。
- XWiki logに`OIDCAuthServiceImpl`のclass読込errorが記録される。
- callback後にtokenのissuer、state、nonce検証が失敗する。

## Rollback

OIDC障害時は`.env`の`XWIKI_AUTHCLASS`を標準認証へ戻す。

```dotenv
XWIKI_AUTHCLASS=com.xpn.xwiki.user.impl.xwiki.XWikiAuthServiceImpl
```

```bash
# 標準認証へ戻した設定でXWikiを再作成する。
sudo docker compose --env-file .env --profile xwiki up -d xwiki

# local管理者で標準認証できることを確認する。
curl --fail-with-body --user "Admin:${XWIKI_LOCAL_ADMIN_PASSWORD}" \
  "http://localhost:33100/rest/wikis/xwiki/user?oidc.skipped=true"
```

OIDC extension、Standard Flavor、両volumeは保持する。認証classだけを戻すため、問題修正後にOIDCを再有効化できる。

## References

- [XWiki Docker Compose required files](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/docker-compose/required-files/)
- [Run XWiki with PostgreSQL on Tomcat](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/docker-compose/run-xwiki-postgresql-tomcat/)
- [XWiki Docker images](https://github.com/xwiki/xwiki-docker)
- [XWiki REST API](https://www.xwiki.org/xwiki/bin/view/Documentation/UserGuide/Features/XWikiRESTfulAPI)
- [XWiki OpenID Connect Authenticator](https://extensions.xwiki.org/xwiki/bin/view/Extension/OpenID%20Connect/OpenID%20Connect%20Authenticator/)
- [XWiki Standard Flavor](https://extensions.xwiki.org/xwiki/bin/view/Extension/XWiki%20Standard%20Flavor/Main%20Wiki/)
