# Initial Setup

Keycloakの初回ログインから、Open-WebUIのKnowledge作成、OIKB連携までの初期設定手順。

## 前提

- `.env`に`PUBLIC_HOST`を設定している。
- `STACK_NAME`を未指定にした場合、Keycloak realm名は`inferlab`になる。
- 初期値のまま起動した場合、Keycloak管理者とrealm内admin userのpasswordはどちらも`admin`。
- Open-WebUI用Keycloak clientは`open-webui`、client secretは`OPEN_WEBUI_OIDC_CLIENT_SECRET`で上書きできる。
- OIKBはNextcloud volumeの`admin/files/oikb`とRustFS bucketの`s3://oikb-bucket/documents`をOpen-WebUI Knowledgeへ同期する。
- 既存のKeycloak realmがある環境では`--import-realm`だけではclient secretが更新されない場合がある。その場合はKeycloak管理consoleで`open-webui` clientのsecretを`OPEN_WEBUI_OIDC_CLIENT_SECRET`と一致させる。

## 1. 基本stackを起動する

```bash
# 初回設定に必要なprofileを起動する。
sudo docker compose --env-file .env --profile common --profile keycloak --profile pubnet --profile inference --profile rag --profile owui --profile nextcloud up -d
```

期待結果:

- Keycloakが`http://${PUBLIC_HOST}:30001`で応答する。
- Open-WebUIが`http://${PUBLIC_HOST}:32000`で応答する。
- Nextcloudが`http://${PUBLIC_HOST}:33000`で応答する。
- OIKBが`http://${PUBLIC_HOST}:32001`で応答する。
- RustFS consoleが`http://${PUBLIC_HOST}:32006`で応答する。

失敗条件:

- `docker compose config --quiet`が失敗する。
- `keycloak`、`open-webui`、`nextcloud`、`oikb`のいずれかがunhealthyになる。

```bash
# 初回設定に必要な主要serviceの状態を確認する。
sudo docker compose --env-file .env --profile common --profile keycloak --profile rag --profile owui --profile nextcloud ps keycloak open-webui nextcloud oikb-rustfs oikb
```

## 2. Keycloakへ初回ログインする

1. `http://${PUBLIC_HOST}:30001`を開く。
2. 管理consoleへ`admin` / `admin`でログインする。
3. 左上のrealm selectorで`inferlab`、または`.env`の`STACK_NAME`で指定したrealmを選ぶ。
4. `Users`で`admin` userが存在し、`admins`と`users` groupに所属していることを確認する。
5. `Clients`で`open-webui` clientが存在し、redirect URIに`http://${PUBLIC_HOST}:32000/oauth/oidc/callback`が含まれることを確認する。

期待結果:

- realm内の`admin` userでOpen-WebUIへOAuth loginできる。
- `open-webui` clientのsecretがOpen-WebUI containerの`OAUTH_CLIENT_SECRET`と一致している。

失敗条件:

- `inferlab` realmが存在しない。
- `open-webui` clientのsecretが一致しない。
- `groups` claimがID tokenまたはuser infoに含まれない。

## 3. Open-WebUIへKeycloakでログインする

1. `http://${PUBLIC_HOST}:32000`を開く。
2. `Keycloak`でログインする。
3. Keycloakのrealm内`admin` userで認証する。
4. Open-WebUIへ戻り、user menuからAPI keyを作成する。

期待結果:

- Open-WebUIにKeycloak認証userが作成される。
- API keyを1つ発行できる。

失敗条件:

- Keycloakログイン後にOpen-WebUIへredirectされない。
- Open-WebUIにAPI key作成画面が表示されない。

## 4. Dify管理者アカウントを作成する

Dify OSS版は、このstackの環境変数だけでは汎用OIDC/Keycloak SSOを有効化しない。管理者アカウントはDifyの初回セットアップ画面で作成する。

```bash
# Dify profileを起動する。
sudo docker compose --env-file .env --profile dify up -d
```

1. `http://${PUBLIC_HOST}:32100/install`を開く。
2. password入力を求められた場合は、`21-dify/docker-compose.yml`の`INIT_PASSWORD`、既定値では`admin`を入力する。
3. 管理者のemail、username、passwordを設定して初回セットアップを完了する。
4. `http://${PUBLIC_HOST}:32100/signin`を開き、作成した管理者アカウントでログインする。

期待結果:

- Difyの管理者アカウントが作成される。
- Dify consoleへログインできる。
- `dify-api`、`dify-web`、`dify-nginx`がhealthyになる。

失敗条件:

- `/install`で`INIT_PASSWORD`が通らない。
- 管理者アカウント作成後に`/signin`へ遷移できない。
- `dify-api`、`dify-web`、`dify-nginx`のいずれかがunhealthyになる。

```bash
# Dify主要serviceの状態を確認する。
sudo docker compose --env-file .env --profile dify ps dify-api dify-web dify-nginx
```

## 5. Open-WebUI Knowledgeを作成する

1. Open-WebUIで`Workspace`から`Knowledge`を開く。
2. Nextcloud同期用とRustFS同期用のKnowledgeを作成する。
3. 作成後のURLまたは画面表示から、それぞれのKnowledge IDを控える。
4. `.env`に次の値を設定する。

```dotenv
OPEN_WEBUI_API_KEY=<Open-WebUIで作成したAPI key>
NEXTCLOUD_OPENWEBUI_KB_ID=<Open-WebUIで作成したKnowledge ID>
RUSTFS_OPENWEBUI_KB_ID=<Open-WebUIで作成したKnowledge ID>
```

期待結果:

- OIKBがOpen-WebUI APIへ接続するためのAPI keyを持つ。
- OIKBがNextcloud同期先とRustFS同期先のKnowledge IDを参照できる。

失敗条件:

- `OPEN_WEBUI_API_KEY`が空のままになっている。
- `NEXTCLOUD_OPENWEBUI_KB_ID`が空のままになっている。
- `RUSTFS_OPENWEBUI_KB_ID`が空のままになっている。

## 6. OIKB同期対象を用意する

### Nextcloud

1. `http://${PUBLIC_HOST}:33000`を開く。
2. `admin` / `admin`でログインする。
3. `oikb` folderを作成する。
4. `oikb/jsdf`と`oikb/dow`を作成する。
5. 同期対象PDFを`oikb/jsdf`または`oikb/dow`へ配置する。

期待結果:

- OIKB containerから`/nextcloud/data/admin/files/oikb`として読み取れる。
- `20-owui/oikb/oikb.yaml`の`source`と一致する。

失敗条件:

- Nextcloud上のfolderが`admin/files/oikb`以外に作成されている。
- PDF以外の不要なURL markerやサンプルfileが同期対象に残っている。

### RustFS

1. `http://${PUBLIC_HOST}:32006`を開く。
2. `.env`の`OIKB_RUSTFS_ACCESS_KEY_ID` / `OIKB_RUSTFS_SECRET_ACCESS_KEY`、または既定値の`rustfs_admin` / `rustfs_secret_key`でログインする。
3. `oikb-bucket` bucketが存在することを確認する。
4. `documents/` prefix配下へ同期対象fileを配置する。

期待結果:

- OIKB containerから`s3://oikb-bucket/documents`として読み取れる。
- `20-owui/oikb/oikb.yaml`の`rustfs-documents` sourceと一致する。

失敗条件:

- `documents/`以外のprefixへfileを配置している。
- `.env`のRustFS認証情報とRustFS containerの認証情報が一致しない。

## 7. OIKBを再起動して同期する

```bash
# .envに設定したOpen-WebUI API keyとKnowledge IDをOIKBへ反映する。
sudo docker compose --env-file .env --profile owui up -d --force-recreate oikb
```

期待結果:

- OIKBがhealthyになる。
- OIKB logにNextcloud sourceまたはRustFS sourceのscanとOpen-WebUI Knowledgeへの同期が出る。
- Open-WebUIのKnowledgeに配置したfileが登録される。

失敗条件:

- OIKB logにOpen-WebUI API認証エラーが出る。
- OIKB logにKnowledge ID未設定のエラーが出る。
- Open-WebUIのKnowledgeにfileが増えない。

```bash
# 既定のSTACK_NAMEでOIKBの同期logを確認する。
sudo docker logs --tail 200 inferlab-oikb
```

## 8. 再実行とrollback

再実行:

```bash
# OIKBだけを再作成して同期設定を再読み込みする。
sudo docker compose --env-file .env --profile owui up -d --force-recreate oikb
```

rollback:

```bash
# OIKBを停止してOpen-WebUI Knowledge同期を止める。
sudo docker compose --env-file .env --profile owui stop oikb
```

期待結果:

- 再実行時はOIKBが同じKnowledge IDへ同期する。
- rollback時はOIKBによる追加同期が停止する。

失敗条件:

- 再実行後も同じ認証エラーが続く。
- rollback後もOIKB containerがrunningのまま残る。
