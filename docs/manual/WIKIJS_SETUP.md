# Wiki.js初期セットアップとKeycloak連携

## 目的

この手順は、`31-wikijs`のWiki.js 2.5.314を初期化し、`01-keycloak`の`prod` realmを認証元として追加するためのものである。

対象構成は次のとおりである。

| 項目 | 値 |
| --- | --- |
| Wiki.js | `http://${PUBLIC_HOST}:33100` |
| Keycloak | `http://${PUBLIC_HOST}:30001` |
| Keycloak realm | `prod` |
| Keycloak client ID | `wikijs` |
| Wiki.js認証module | `Keycloak` |
| OIDC flow | Authorization Code Flow（KeycloakのStandard Flow） |

## 初期セットアップとKeycloak連携の順序

通常の管理画面を使う場合、Wiki.jsの初期セットアップはKeycloak連携の前提である。

[Wiki.js 2.5.314のsetup処理](https://github.com/requarks/wiki/blob/v2.5.314/server/setup.js)はsite URL、root管理者、`Administrators` group、`Guests` group、無効化できない`Local`認証strategyを作成する。認証strategyの追加はその後にAdministration画面で行う。さらに、[Wiki.jsの認証初期化処理](https://github.com/requarks/wiki/blob/v2.5.314/server/core/auth.js)は、strategy追加時に生成されるUUIDを使ってredirect URIを`<site URL>/login/<strategy UUID>/callback`とする。このため、Keycloak自体は先に起動できるが、厳密なredirect URIを確定するには次の順序で進める。

1. Wiki.jsのsetup wizardを完了する。
2. local管理者でWiki.jsへloginする。
3. Wiki.jsで`Keycloak` strategyを追加し、表示されたcallback URLを取得する。
4. Keycloakの`prod` realmへ`wikijs` clientとcallback URLを登録する。
5. Wiki.jsへclient secretとendpointを設定してstrategyを有効化する。
6. 別browser sessionでKeycloak loginを検証する。

Wiki.jsのDBへ直接認証設定を投入する方法は、この手順の対象外とする。

## Repositoryの現状と事前条件

Wiki.jsとPostgreSQLのimage、port、DB接続は[Wiki.js Compose定義](../../31-wikijs/docker-compose.yml)にある。Keycloakは[Keycloak Compose定義](../../01-keycloak/docker-compose.yml)により`prod` realmを作成し、[Keycloak宣言設定](../../01-keycloak/keycloak/config.yaml)を同期する。

2026-08-21時点のKeycloak宣言設定には`wikijs` clientがない。そのままでは連携できないため、本手順ではsetup後にKeycloak管理consoleでclientを作成する。clientを宣言管理へ移す場合は、strategy UUIDを確定した後に、少なくともclient ID、client secret、厳密なredirect URI、Web OriginをKeycloak宣言設定へ反映する。

作業前に次を準備する。

- `PUBLIC_HOST`からWiki.jsとKeycloakの両方へbrowserで接続できること。
- Wiki.js初期管理者用のmail addressと十分に強いpassword。
- Keycloakのmaster realm管理者credential。
- Keycloak userを所属させるWiki.js groupの権限方針。
- 既存Wiki.js dataがある場合はPostgreSQL backup。

## Containerの起動

repository rootで実行する。

```bash
# 後続のHTTP確認でも.envのPUBLIC_HOSTを使えるよう、変数をexportする。
set -a
# repositoryの環境変数を現在のshellへ読み込む。
. ./.env
# 以後に作成するshell変数の自動exportを解除する。
set +a

# KeycloakとWiki.jsのprofileを起動する。
sudo docker compose --env-file .env --profile keycloak --profile wikijs up -d

# 初期化serviceを含む対象containerの状態を確認する。
sudo docker compose --env-file .env --profile keycloak --profile wikijs ps --all keycloak keycloak-config keycloak-https keycloak-postgres wikijs wikijs-postgres

# Keycloakのprod realmが公開するOIDC discovery documentを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:30001/realms/prod/.well-known/openid-configuration" >/dev/null

# Wiki.jsのHTTP endpointが応答することを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:33100/" >/dev/null
```

期待結果:

- `keycloak`、`keycloak-https`、`keycloak-postgres`、`wikijs`、`wikijs-postgres`が`running`または`healthy`になる。
- `keycloak-config`がexit code `0`で終了する。
- Keycloak discovery endpointとWiki.jsが2xx responseを返す。
- 未初期化のWiki.jsをbrowserで開くとsetup wizardが表示される。

失敗条件:

- いずれかの永続serviceが再起動を繰り返すか、`unhealthy`になる。
- `keycloak-config`が非0で終了する。
- discovery endpointが404または5xxを返す。
- Wiki.js logにDB接続errorが記録される。

## Wiki.jsの初期セットアップ

1. Browserで`http://${PUBLIC_HOST}:33100`を開く。
2. `Administrator Email`へ初期管理者のmail addressを入力する。
3. `Password`と`Confirm Password`へ同じ十分に強いpasswordを入力する。
4. `Site URL`へ末尾slashなしで`http://${PUBLIC_HOST}:33100`を入力する。
5. Telemetryを利用方針に合わせて選択する。
6. `Install`を選択し、`/login`へ遷移するまで待つ。
7. `Local`を選択し、入力した初期管理者credentialでloginする。

`Site URL`はbrowserから見える公開URLを設定する。Container内部の`http://wikijs:3000`を設定すると、後で生成されるOIDC callback URLがbrowserから到達できない値になる。

期待結果:

- setup wizardが完了し、login画面へ遷移する。
- local管理者でloginできる。
- Administration画面を開ける。
- 再読込してもsetup wizardへ戻らない。

失敗条件:

- mail addressの形式errorが表示される。
- password確認が一致しない。
- `Site URL`の末尾にslashがありvalidation errorになる。
- `Install`後にDB migrationまたは初期data作成errorが表示される。

## Keycloak user用groupの準備

Keycloak認証に成功しただけではWiki.jsのpage権限は付与されない。Wiki.jsのAdministrationでKeycloak user用groupを作成し、必要なglobal permissionとpage ruleだけを付与する。

例として`Users` groupを作成する場合は、次の方針を使う。

- 一般userへ`Administrators` groupを割り当てない。
- 閲覧、編集、asset操作など、必要なglobal permissionだけを選択する。
- 対象pathとlocaleをpage ruleで制限する。
- Keycloak strategyのself-registration先としてこのgroupを選択する。

[Wiki.js 2.5.314のKeycloak module実装](https://github.com/requarks/wiki/blob/v2.5.314/server/modules/authentication/keycloak/authentication.js)はKeycloak profileのID、mail address、表示名をuser処理へ渡すが、`groups` claimをWiki.js groupへ直接同期しない。初回login時の所属先はWiki.js側の`Self-registration`と`Assign to group`で管理する。[Wiki.js公式のAuthentication手順](https://docs.requarks.io/auth)も、新規userを許可する場合はstrategy単位のself-registrationと既存groupへの割当を設定するよう案内している。

期待結果:

- Keycloak userへ割り当てるgroupが存在する。
- groupに許可したpageだけを閲覧または編集できる権限設計になっている。

失敗条件:

- 一般userを`Administrators`へ自動登録する。
- global permissionだけ、またはpage ruleだけを設定し、必要な操作ができない。

## Wiki.jsでcallback URLを確定

1. Local管理者でWiki.jsへloginする。
2. Administrationの`Authentication`を開く。
3. `Add Strategy`から`Keycloak`を選択する。
4. `Display Name`を`Keycloak`など利用者が識別できる名前にする。
5. 画面下部の`Configuration Reference`に表示される`Callback URL / Redirect URI`を控える。
6. この段階では無効なclient設定で`Apply`せず、Keycloak clientを先に作成する。

callback URLは次の形式だが、`<strategy UUID>`は環境ごとに異なる。例のUUIDを流用してはならない。

```text
http://${PUBLIC_HOST}:33100/login/<strategy UUID>/callback
```

期待結果:

- `Allowed Web Origins`が`http://${PUBLIC_HOST}:33100`になる。
- callback URLが`http://${PUBLIC_HOST}:33100/login/`で始まり、`/callback`で終わる。
- UUIDを含むcallback URLをそのまま控えられる。

失敗条件:

- Configuration Referenceに内部container URLが表示される。
- callback URLのhost、scheme、portが実際のbrowser access URLと異なる。
- Strategyを削除して作り直した後も古いUUIDを使う。

## Keycloak clientの作成

1. `http://${PUBLIC_HOST}:30001/admin/`を開き、master realm管理者でloginする。
2. 左上のrealm selectorで`prod`を選択する。
3. `Clients`からOpenID Connect clientを作成する。
4. `Client ID`を`wikijs`、nameを`Wiki.js`にする。
5. `Client authentication`を有効、`Standard Flow`を有効にする。Wiki.jsはserver側でcodeをtokenへ交換するため、client secretを持つconfidential clientとして構成する。
6. `Direct Access Grants`、`Implicit Flow`、`Service Accounts`は無効にする。
7. `Root URL`と`Home URL`へ`http://${PUBLIC_HOST}:33100/`を設定する。
8. `Valid redirect URIs`へWiki.jsから控えたcallback URLを完全一致で1件登録する。
9. `Web origins`へ`http://${PUBLIC_HOST}:33100`を登録する。
10. 保存後、`Credentials`でclient secretを取得し、安全なcredential storeへ保存する。

[KeycloakのAuthorization Code Flow](https://www.keycloak.org/docs/latest/server_admin/#_oidc-auth-flows)では、認証後にclientが指定したcallback URLへ一時codeを返し、confidential clientはtoken交換時にclient secretを提示する。`Valid redirect URIs`へ広いwildcardを設定すると、意図しないredirect先を許可する範囲が広がるため、strategy UUIDの確定後はWiki.js画面に表示されたURIを完全一致で登録する。

期待結果:

- `prod` realmに有効な`wikijs` clientが存在する。
- Client authenticationとStandard Flowだけが要件に沿って有効になる。
- Valid redirect URIがWiki.jsのConfiguration Referenceと完全一致する。
- Client secretをWiki.jsへ入力できる。

失敗条件:

- `master` realmへclientを作成する。
- Public clientとして作成し、client secretが発行されない。
- callback URLのscheme、host、port、UUID、末尾pathのいずれかが異なる。

## Wiki.jsのKeycloak strategy設定

[Wiki.js 2.5.314のKeycloak module定義](https://github.com/requarks/wiki/blob/v2.5.314/server/modules/authentication/keycloak/definition.yml)に従い、Wiki.jsのKeycloak strategyへ次を設定する。各endpoint pathは[Keycloak公式のOIDC endpoint一覧](https://www.keycloak.org/securing-apps/oidc-layers)に従う。

| Wiki.js項目 | 値 |
| --- | --- |
| Host | `http://${PUBLIC_HOST}:30001` |
| Realm | `prod` |
| Client ID | `wikijs` |
| Client Secret | Keycloakで取得したsecret |
| Authorization Endpoint URL | `http://${PUBLIC_HOST}:30001/realms/prod/protocol/openid-connect/auth` |
| Token Endpoint URL | `http://${PUBLIC_HOST}:30001/realms/prod/protocol/openid-connect/token` |
| User Info Endpoint URL | `http://${PUBLIC_HOST}:30001/realms/prod/protocol/openid-connect/userinfo` |
| Logout from Keycloak on Logout | 有効 |
| Logout Endpoint URL | `http://${PUBLIC_HOST}:30001/realms/prod/protocol/openid-connect/logout` |
| Legacy Logout Redirect | 無効 |
| Self-registration | 有効 |
| Assign to group | 前項で作成した一般user用group |
| Active | 有効 |

[Wiki.js 2.5.314のKeycloak logout実装](https://github.com/requarks/wiki/blob/v2.5.314/server/modules/authentication/keycloak/authentication.js)は、Keycloak 18以降でID tokenを伴う`post_logout_redirect_uri`を使うため、Keycloak 26では`Legacy Logout Redirect`を無効にする。

設定後に`Apply`を選択する。`Local` strategyはroot管理者の復旧経路として残す。Keycloak loginを確認する前にlocal providerをlogin画面から隠さない。

期待結果:

- Applyがerrorなく完了する。
- Wiki.jsのlogin画面に`Keycloak`が表示される。
- Wiki.js logに`Authentication Strategy Keycloak: [ OK ]`が記録される。

失敗条件:

- Client secretをrepository、document、terminal logへ記録する。
- Self-registrationを無効のままにし、事前登録していないKeycloak userでloginする。
- Keycloak endpointへWiki.js containerから到達できない。

## 動作確認

まずWiki.js containerからKeycloak discovery endpointへ到達できることを確認する。OIDCのtoken交換とUserInfo取得はbrowserではなくWiki.js serverから実行されるため、host側の`curl`だけでは確認として不十分である。

```bash
# Wiki.js containerからPUBLIC_HOST経由でKeycloak discovery endpointを取得する。
sudo docker compose --env-file .env --profile wikijs exec -T wikijs wget -qO- "http://${PUBLIC_HOST:-localhost}:30001/realms/prod/.well-known/openid-configuration" >/dev/null

# Wiki.jsとKeycloakの直近logを確認する。
sudo docker compose --env-file .env --profile keycloak --profile wikijs logs --since=10m wikijs keycloak
```

次に、既存local管理者sessionを残したまま、private browsing windowなど別sessionで確認する。

1. `http://${PUBLIC_HOST}:33100/login`を開く。
2. `Keycloak`を選択する。
3. `prod` realmのuserで認証する。
4. Wiki.jsへ戻り、login済みになることを確認する。
5. 対象userが指定したWiki.js groupへ登録されていることをAdministrationで確認する。
6. 許可したpage操作が成功し、許可していない管理操作が拒否されることを確認する。
7. Wiki.jsからlogoutし、Keycloak logout後にWiki.jsへ戻ることを確認する。
8. 最後にlocal管理者でも引き続きloginできることを確認する。

期待結果:

- Keycloakで認証後、同じWiki.js callback URLへ戻る。
- 初回loginでWiki.js userが作成され、指定groupへ所属する。
- 2回目以降は同じWiki.js userとしてloginする。
- Logout後に保護pageを再表示するとloginが必要になる。
- Local管理者loginが復旧経路として機能する。

失敗条件:

- Keycloakに`Invalid parameter: redirect_uri`が表示される。
- Wiki.jsに`Failed to obtain access token`または`Missing or invalid email address from profile`が表示される。
- 認証後に`You are not authorized to login`が表示される。
- 同じKeycloak userでloginするたびに別のWiki.js userが作成される。
- 一般userへ管理権限が付与される。

## Troubleshooting

| 症状 | 主な確認箇所 |
| --- | --- |
| `Invalid parameter: redirect_uri` | Wiki.jsのConfiguration ReferenceとKeycloakのValid redirect URIを文字単位で比較する。Site URL、scheme、host、port、strategy UUIDを確認する。 |
| `Failed to obtain access token` | Client secret、Token Endpoint URL、Wiki.js containerからKeycloakへの到達性を確認する。 |
| `Missing or invalid email address from profile` | Keycloak userにmail addressがあり、`email` scopeでclaimが返ることを確認する。 |
| `You are not authorized to login` | Wiki.jsのSelf-registration、domain whitelist、Assign to groupを確認する。 |
| Login後にpageを表示できない | 自動登録先groupのglobal permissionとpage ruleを両方確認する。 |
| LogoutでKeycloak errorになる | Keycloak 26ではLegacy Logout Redirectを無効にし、Logout Endpoint URLを確認する。 |

## Rollback

### Keycloak連携だけを戻す

1. Local管理者でWiki.jsへloginする。
2. AdministrationのAuthenticationでKeycloak strategyを無効化または削除する。
3. Keycloakの`prod` realmで`wikijs` clientを無効化または削除する。
4. Wiki.jsのlocal loginとpage表示を確認する。

このrollbackではWiki.jsのpageとlocal userを保持する。Keycloak経由で自動登録されたWiki.js userを削除するかは、data保持方針に基づき別途判断する。

期待結果:

- Login画面でKeycloak loginを利用できなくなる。
- Local管理者loginは継続して利用できる。
- Wiki.jsのpage dataは失われない。

失敗条件:

- Local管理者loginを確認せずKeycloak strategyを削除する。
- Keycloak clientだけ削除し、Wiki.js側に利用不能なactive strategyを残す。

### Wiki.jsを完全再初期化する

完全再初期化はWiki.jsの設定、page、user、API keyを失う。必要な場合だけ実行する。

```bash
# 再初期化前のWiki.js PostgreSQL backupを作成する。
sudo docker compose --env-file .env --profile wikijs exec -T wikijs-postgres pg_dump -U wikijs_db_user -d wikijs > "wikijs-before-reset-$(date +%Y%m%d-%H%M%S).sql"

# Wiki.js専用containerだけを停止する。
sudo docker compose --env-file .env --profile wikijs stop wikijs wikijs-postgres

# 停止済みのWiki.js専用containerだけを削除する。
sudo docker compose --env-file .env --profile wikijs rm -f wikijs wikijs-postgres

# .env内のSTACK_NAMEを現在のshellへ読み込む。
set -a
# repositoryの環境変数を現在のshellへ読み込む。
. ./.env
# 以後に作成するshell変数の自動exportを解除する。
set +a

# 対象がWiki.js専用volumeであることを表示して確認する。
sudo docker volume inspect "${STACK_NAME}_wikijs-postgres-data"

# 確認済みのWiki.js専用volumeだけを削除する。
sudo docker volume rm "${STACK_NAME}_wikijs-postgres-data"

# 空のPostgreSQL volumeでWiki.jsを再作成する。
sudo docker compose --env-file .env --profile wikijs up -d
```

期待結果:

- PostgreSQL dump fileが作成される。
- 削除対象が`wikijs-postgres-data`だけであることを確認できる。
- 再起動後にsetup wizardが表示される。

失敗条件:

- Backupを取得せず既存dataが必要になる。
- `docker volume inspect`で対象を確認していない。
- Wiki.js以外のvolumeを削除する。
- Volumeが使用中のままで削除に失敗する。

## References

- [Wiki.js Docker installation](https://docs.requarks.io/install/docker)
- [Wiki.js Authentication](https://docs.requarks.io/auth)
- [Wiki.js v2.5.314 setup UI source](https://github.com/requarks/wiki/blob/v2.5.314/client/components/setup.vue)
- [Wiki.js v2.5.314 setup server source](https://github.com/requarks/wiki/blob/v2.5.314/server/setup.js)
- [Wiki.js v2.5.314 authentication callback source](https://github.com/requarks/wiki/blob/v2.5.314/server/core/auth.js)
- [Wiki.js v2.5.314 authentication administration UI source](https://github.com/requarks/wiki/blob/v2.5.314/client/components/admin/admin-auth.vue)
- [Wiki.js v2.5.314 Keycloak module definition](https://github.com/requarks/wiki/blob/v2.5.314/server/modules/authentication/keycloak/definition.yml)
- [Wiki.js v2.5.314 Keycloak module implementation](https://github.com/requarks/wiki/blob/v2.5.314/server/modules/authentication/keycloak/authentication.js)
- [Wiki.js v2.5.314 user profile processing source](https://github.com/requarks/wiki/blob/v2.5.314/server/models/users.js)
- [Keycloak Server Administration Guide](https://www.keycloak.org/docs/latest/server_admin/)
- [Keycloak OpenID Connect endpoints](https://www.keycloak.org/securing-apps/oidc-layers)
- [Wiki.js Compose定義](../../31-wikijs/docker-compose.yml)
- [Keycloak Compose定義](../../01-keycloak/docker-compose.yml)
- [Keycloak宣言設定](../../01-keycloak/keycloak/config.yaml)
