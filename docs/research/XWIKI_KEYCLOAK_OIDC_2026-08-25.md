# XWikiとKeycloakのOIDC連携調査（2026-08-25）

## 結論

`31-xwiki`のXWiki 18.4.4は、XWiki公式のOpenID Connect Authenticator 2.25.4を使用して、`01-keycloak`のKeycloak 26.7.2と連携できる。OpenID Connect Authenticator 2.25.4が要求する最小XWiki versionは14.10.2であるため、version上の互換性条件を満たしている。

推奨する導入順序は次のとおりである。

1. OIDCを有効化していない状態でXWikiのDistribution Wizardを完了する。
2. XWikiのExtension Managerから`org.xwiki.contrib.oidc:oidc-authenticator` 2.25.4をroot namespaceへ導入する。
3. Keycloakへ`xwiki` confidential clientを追加する。
4. XWikiへOIDC設定を環境変数で注入し、containerを再作成する。
5. Keycloak login、XWiki user作成、group同期、logoutを検証する。

通常の初期構築では、Distribution Wizardの完了前にKeycloak連携を有効化すべきではない。Authenticatorのclassをextension導入前に指定するとclassを読み込めず、XWikiへloginできなくなる危険がある。手動でJARと全依存関係を`WEB-INF/lib`へ事前配置する方法は公式に用意されているため、技術的に初期設定前の導入も可能ではあるが、このrepositoryではExtension Managerを使う段階的な導入のほうが単純で安全である。

## 現行構成

| 項目 | 現在値 | 根拠 |
|---|---|---|
| XWiki image | `docker.io/library/xwiki:18.4.4-postgres-tomcat` | `31-xwiki/docker-compose.yml` |
| XWiki公開URL | `http://${PUBLIC_HOST}:33100` | `31-xwiki/docker-compose.yml` |
| XWiki context path | ROOT | `CONTEXT_PATH`を指定していないため |
| Keycloak image | `quay.io/keycloak/keycloak:26.7.2` | `01-keycloak/docker-compose.yml` |
| Keycloak realm | `prod` | `01-keycloak/keycloak/config.yaml` |
| Keycloak issuer | `http://${PUBLIC_HOST}:30001/realms/prod` | `KC_HOSTNAME`とrealm名から決定 |
| Keycloak設定同期 | `keycloak-config-cli` 6.5.1-26 | `01-keycloak/docker-compose.yml` |

XWikiとKeycloakは共通の`internal-nw`へ接続する。ただし、XWikiの`oidc.provider`にはcontainer内URLの`http://keycloak:8080/realms/prod`ではなく、tokenの`iss`と一致する公開issuerの`http://${PUBLIC_HOST}:30001/realms/prod`を使用する必要がある。XWiki containerからもこの公開URLへ到達できることが前提になる。

## XWiki extension

導入対象は次のextensionである。

| 項目 | 値 |
|---|---|
| Extension ID | `org.xwiki.contrib.oidc:oidc-authenticator` |
| 採用version | `2.25.4` |
| 最小XWiki version | `14.10.2` |
| 現行XWikiとの判定 | XWiki 18.4.4で利用可能 |

2026-08-25時点で、XWiki Extension Repositoryが公開するrelease最新版は2.25.4である。Authenticatorはserver全体から読み込むcomponentを含むため、root namespaceへ導入する。Extension Managerを使用すると、`oidc-provider`、`oidc-authenticator-configuration`、`oidc-authenticator-user`、`oauth2-store`などの依存extensionも解決される。

extensionとその依存関係はXWikiのpermanent directoryおよびdatabaseと関係するため、`xwiki-data`と`xwiki-postgres-data`の両volumeを維持する。片方だけを初期化すると、導入済みextensionとwiki内objectの状態が不整合になる可能性がある。

## 初期セットアップの制約

Distribution Wizardは初回起動時に管理者とFlavorを導入し、その処理自体がExtension Managerを使用する。推奨手順では、最初にローカル認証でDistribution Wizardを完了して管理画面へ入れる状態にし、その後にOIDC Authenticatorを導入する。

Extension Managerによるoffline導入は公式にはサポートされていない。初期セットアップとOIDC Authenticator導入時はextension repositoryへ接続できる環境を用意する。閉域環境だけで完結させる場合は、全transitive dependencyを含む手動配置または専用imageを別途設計する必要がある。

OIDCを有効化する`xwiki.authentication.authclass`はextension導入後に設定する。初回起動からこの値を設定してはならない。

OIDC有効化後も、検証期間中は`oidc.tryLocal=true`を維持する。これにより、KeycloakやOIDC設定に問題がある場合にXWikiのローカル管理者で復旧できる。OIDC Authenticatorは`oidc.skipped=true` query parameterによる一時回避も提供する。運用確認後にローカルloginを禁止する場合だけ`oidc.tryLocal=false`へ変更する。

## 環境変数によるXWiki設定

XWiki 17.5.0以降は、`xwiki.cfg`と`xwiki.properties`の値をJava system propertyまたは環境変数で上書きできる。XWiki 18.4.4はこの機能を利用できるため、設定ファイルのbind mountや起動scriptによる書き換えは不要である。

環境変数名は`XCONF_<configuration source>_<encoded property name>`形式である。`.`、`:`、`-`は`_`へ置換し、property名の大文字・小文字は維持する。

最小設定は次のとおりである。

| XWiki property | Compose環境変数 | 推奨値 |
|---|---|---|
| `xwiki.authentication.authclass` | `XCONF_xwikicfg_xwiki_authentication_authclass` | `org.xwiki.contrib.oidc.auth.OIDCAuthServiceImpl` |
| `oidc.provider` | `XCONF_xwikiproperties_oidc_provider` | `http://${PUBLIC_HOST}:30001/realms/prod` |
| `oidc.clientid` | `XCONF_xwikiproperties_oidc_clientid` | `xwiki` |
| `oidc.secret` | `XCONF_xwikiproperties_oidc_secret` | `${XWIKI_OIDC_CLIENT_SECRET}` |
| `oidc.scope` | `XCONF_xwikiproperties_oidc_scope` | `openid,profile,email` |
| `oidc.endpoint.token.auth_method` | `XCONF_xwikiproperties_oidc_endpoint_token_auth_method` | `client_secret_basic` |
| `oidc.user.nameFormater` | `XCONF_xwikiproperties_oidc_user_nameFormater` | `${oidc.user.preferredUsername._clean._lowerCase}` |
| `oidc.tryLocal` | `XCONF_xwikiproperties_oidc_tryLocal` | `true` |
| `oidc.afterLogoutURL` | `XCONF_xwikiproperties_oidc_afterLogoutURL` | `/` |

`oidc.provider`からOpenID Provider Configurationを検出できるため、authorization、token、userinfo、logoutの各endpointを個別に設定する必要はない。

Composeへ記載する場合の構成例は次のとおりである。これは実装案であり、本調査ではdeployment fileへ反映していない。

```yaml
services:
  xwiki:
    environment:
      # Extension導入後にOIDC Authenticatorを有効化する。
      XCONF_xwikicfg_xwiki_authentication_authclass: org.xwiki.contrib.oidc.auth.OIDCAuthServiceImpl
      # Keycloakがtokenへ設定する公開issuerをdiscoveryの起点にする。
      XCONF_xwikiproperties_oidc_provider: http://${PUBLIC_HOST}:30001/realms/prod
      XCONF_xwikiproperties_oidc_clientid: xwiki
      XCONF_xwikiproperties_oidc_secret: ${XWIKI_OIDC_CLIENT_SECRET:?XWIKI_OIDC_CLIENT_SECRET must be set}
      XCONF_xwikiproperties_oidc_scope: openid,profile,email
      XCONF_xwikiproperties_oidc_endpoint_token_auth_method: client_secret_basic
      # Composeによる展開を避け、XWikiへformatter式をそのまま渡す。
      XCONF_xwikiproperties_oidc_user_nameFormater: $${oidc.user.preferredUsername._clean._lowerCase}
      # 検証中にローカル管理者で復旧できる状態を保つ。
      XCONF_xwikiproperties_oidc_tryLocal: "true"
      XCONF_xwikiproperties_oidc_afterLogoutURL: /
```

`oidc.secret`は平文の`xwiki.properties`へ保存せず、`.env`またはsecret管理基盤からCompose環境変数へ渡す。repositoryには実secretをcommitしてはならない。

## Keycloak client

Keycloakへ追加するclientの最小構成は次のとおりである。

| 項目 | 推奨値 | 理由 |
|---|---|---|
| Client ID | `xwiki` | XWiki側の`oidc.clientid`と一致させる。 |
| Client authentication | 有効 | XWikiはserver-side confidential clientとしてsecretを保持できる。 |
| Standard Flow | 有効 | Authorization Code Flowを使用する。 |
| Implicit Flow | 無効 | 不要なflowを公開しない。 |
| Direct Access Grants | 無効 | password grantを使用しない。 |
| Service Accounts | 無効 | client credentials grantを使用しない。 |
| Root URL | `http://${PUBLIC_HOST}:33100/` | XWikiの公開root。 |
| Valid Redirect URI | `http://${PUBLIC_HOST}:33100/oidc/authenticator/callback` | ROOT contextでXWiki 18.4.4とOIDC Authenticator 2.25.4が生成したcallback endpoint。 |
| Web Origin | `http://${PUBLIC_HOST}:33100` | XWikiの公開origin。 |
| Valid Post Logout Redirect URI | `http://${PUBLIC_HOST}:33100/` | `oidc.afterLogoutURL=/`と一致させる。 |

Keycloakの`redirectUris`はcase-sensitiveなexact matchを基本とする。XWikiを`localhost`や`127.0.0.1`でも使用する場合は、それぞれの`/oidc/authenticator/callback`を明示的に追加する。広い`*`だけのredirect URIは使用しない。

`keycloak-config-cli`向けのclient案は次のとおりである。

```yaml
clients:
  - clientId: xwiki
    name: XWiki
    enabled: true
    protocol: openid-connect
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: "$(env:XWIKI_OIDC_CLIENT_SECRET)"
    standardFlowEnabled: true
    implicitFlowEnabled: false
    directAccessGrantsEnabled: false
    serviceAccountsEnabled: false
    rootUrl: "http://$(env:PUBLIC_HOST):33100/"
    attributes:
      post.logout.redirect.uris: "http://$(env:PUBLIC_HOST):33100/"
    redirectUris:
      - "http://$(env:PUBLIC_HOST):33100/oidc/authenticator/callback"
    webOrigins:
      - "http://$(env:PUBLIC_HOST):33100"
    protocolMappers:
      - name: groups
        protocol: openid-connect
        protocolMapper: oidc-group-membership-mapper
        consentRequired: false
        config:
          claim.name: groups
          full.path: "false"
          introspection.token.claim: "true"
          multivalued: "true"
          id.token.claim: "true"
          access.token.claim: "true"
          userinfo.token.claim: "true"
```

`01-keycloak/docker-compose.yml`の`keycloak-config`には、同じ`XWIKI_OIDC_CLIENT_SECRET`を渡す必要がある。Keycloak側とXWiki側でClient IDまたはsecretが異なるとtoken交換が失敗する。

## group同期

現行Keycloak設定は、各clientへ`groups` claimを追加するgroup membership mapperを使用している。XWiki OIDC Authenticatorの既定claim名は`xwiki_groups`であるため、そのままでは一致しない。

Keycloakの既存mapperを再利用する場合は、XWiki側へ次を追加する。

```yaml
services:
  xwiki:
    environment:
      # Keycloakの既存group membership mapperが出力するclaim名を指定する。
      XCONF_xwikiproperties_oidc_groups_claim: groups
      # group同期を有効化するためgroupsをuserinfo claimへ含める。
      XCONF_xwikiproperties_oidc_userinfoclaims: xwiki_user_accessibility,xwiki_user_company,xwiki_user_displayHiddenDocuments,xwiki_user_editor,xwiki_user_usertype,groups
      # KeycloakのadminsだけをXWikiの管理者groupへ対応付ける。
      XCONF_xwikiproperties_oidc_groups_mapping: XWikiAdminGroup=admins
```

明示的なmappingを設定すると、未定義のKeycloak groupをXWikiへ無制限に作成せずに済む。最初は`admins`から`XWiki.XWikiAdminGroup`へのmappingだけを使用し、必要なgroupを後から追加するのが安全である。

Keycloak側のprotocol mapperには、少なくとも次の設定が必要である。

- claim名を`groups`にする。
- multi-valued claimとして出力する。
- UserInfo responseへ含める。
- group pathは既存設定と同じく短縮名を使う場合、`full.path=false`にする。

## logout

XWiki OIDC Authenticatorはprovider metadataの`end_session_endpoint`を検出し、XWikiからのlogout時にKeycloakへRP-Initiated Logoutを送る。XWiki 2.25.4は`client_id`、保持しているID Token、`post_logout_redirect_uri`をlogout requestへ設定する。

Keycloakは`post_logout_redirect_uri`がclientのValid Post Logout Redirect URIと一致することを要求する。この構成では、XWiki側を`oidc.afterLogoutURL=/`、Keycloak側を`http://${PUBLIC_HOST}:33100/`へ揃える。

Keycloak管理画面や別clientからのlogoutもXWiki sessionへ伝播させる場合は、XWikiが公開する`/oidc/authenticator/backchannel_logout`をKeycloak clientのBackchannel Logout URLへ設定できる。共通Docker networkから到達させる場合の候補は`http://xwiki:8080/oidc/authenticator/backchannel_logout`である。これは通常loginとRP-Initiated Logoutの確認後に追加検証する。

## 検証手順

### 設定検証

```bash
# Composeの変数展開とschemaを検証する。
sudo docker compose --env-file .env --profile keycloak --profile xwiki config >/dev/null

# Keycloakのissuer metadataを取得できることを確認する。
curl -fsS "http://${PUBLIC_HOST}:30001/realms/prod/.well-known/openid-configuration" >/dev/null

# XWikiとKeycloakの起動logにOIDC errorがないことを確認する。
sudo docker compose --env-file .env --profile keycloak --profile xwiki logs --tail=200 xwiki keycloak keycloak-config
```

期待結果:

- Compose設定がerrorなしで展開される。
- discovery endpointがHTTP 200を返す。
- metadataの`issuer`が`http://${PUBLIC_HOST}:30001/realms/prod`と完全一致する。
- `keycloak-config`が正常終了し、`xwiki` clientが作成される。
- XWiki logにAuthenticator classの読込失敗が出ない。

失敗条件:

- `XWIKI_OIDC_CLIENT_SECRET`が未設定でCompose展開に失敗する。
- XWiki containerから公開issuerへ到達できない。
- `issuer`、Client ID、secretのいずれかが不一致になる。

### login検証

1. private browsing windowで`http://${PUBLIC_HOST}:33100/`へaccessする。
2. Keycloakのlogin画面へredirectされることを確認する。
3. `prod` realmのuserでloginする。
4. browserが`/oidc/authenticator/callback`へ戻り、XWiki homeを表示することを確認する。
5. XWikiに対応するuser profileが作成され、emailと表示名が同期されることを確認する。
6. `admins`所属userでは`XWiki.XWikiAdminGroup`への所属と管理画面へのaccessを確認する。

失敗条件:

- Keycloakが`invalid_redirect_uri`を返す。
- token endpointが`invalid_client`を返す。
- XWikiがissuer、state、nonce、ID Tokenの検証に失敗する。
- loginは成功するがgroup claimがUserInfoに含まれず、管理者groupが同期されない。

### logout検証

1. XWikiからlogoutする。
2. Keycloakのlogout endpointを経由することを確認する。
3. `http://${PUBLIC_HOST}:33100/`へ戻ることを確認する。
4. XWikiへ再accessしたとき、Keycloak loginが再度必要になることを確認する。

Keycloakが`invalid_redirect_uri`を返す場合は、clientの`post.logout.redirect.uris`とXWikiが送信した`post_logout_redirect_uri`を比較する。

## rollback

OIDC有効化後にloginできない場合は、XWiki serviceから`XCONF_xwikicfg_xwiki_authentication_authclass`を外してcontainerを再作成し、標準Authenticatorへ戻す。`oidc.tryLocal=true`が有効なら、`oidc.skipped=true`を付けたURLからローカル管理者loginを試せる。

extensionを削除する必要はない。まずOIDC Authenticatorの有効化だけを戻し、issuer、redirect URI、Client ID、secret、group mapperを修正してから再度有効化する。

## 実装判断

- XWikiの設定は、現行versionで利用できる`XCONF_*`環境変数を使用する。
- OIDC Authenticatorは2.25.4へversion固定する。
- Distribution Wizardとextension導入が完了するまでAuthenticator classを切り替えない。
- Keycloak clientはAuthorization Code Flowだけを有効にしたconfidential clientにする。
- callback URIとpost-logout URIは公開hostへ限定し、不要なwildcardを避ける。
- 最初の動作確認では`oidc.tryLocal=true`を維持する。
- Keycloakの既存`groups` mapperを再利用し、`admins`だけをXWiki管理者groupへ明示的にmappingする。

## References

- [XWiki: OpenID Connect Authenticator](https://extensions.xwiki.org/xwiki/bin/view/Extension/OpenID%20Connect/OpenID%20Connect%20Authenticator/)
- [XWiki: OpenID Authentication with Keycloak](https://extensions.xwiki.org/xwiki/bin/view/Extension/OpenID%20Connect/OpenID%20Connect%20Authenticator/OpenID%20Authentication%20with%20Keycloak/)
- [XWiki OIDC source repository](https://github.com/xwiki-contrib/oidc)
- [XWiki OIDC Authenticator 2.25.4 POM](https://github.com/xwiki-contrib/oidc/blob/oidc-2.25.4/oidc-authenticator/pom.xml)
- [XWiki OIDC Authenticator Maven metadata](https://nexus.xwiki.org/nexus/content/groups/public/org/xwiki/contrib/oidc/oidc-authenticator/maven-metadata.xml)
- [XWiki: Extension Manager Application](https://extensions.xwiki.org/xwiki/bin/view/Extension/Extension%2BManager%2BApplication)
- [XWiki: Configuration Module](https://extensions.xwiki.org/xwiki/bin/view/Extension/Configuration%20Module)
- [XWiki: Distribution Wizard](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/distribution-wizard/)
- [XWiki Docker entrypoint for 18.4 PostgreSQL/Tomcat](https://github.com/xwiki/xwiki-docker/blob/master/18.4/postgres-tomcat/xwiki/docker-entrypoint.sh)
- [Keycloak: Server Administration Guide](https://www.keycloak.org/docs/latest/server_admin/)
- [Keycloak: OIDC endpoints](https://www.keycloak.org/securing-apps/oidc-layers)
- [OpenID Connect RP-Initiated Logout 1.0](https://openid.net/specs/openid-connect-rpinitiated-1_0.html)
