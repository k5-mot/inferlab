# Initial Setup

Keycloakの初回ログインから、Open-WebUIのKnowledge作成、OIKB連携までの初期設定手順。

## 前提

- `.env`に`PUBLIC_HOST`を設定している。
- `STACK_NAME`を未指定にした場合、Keycloak realm名は`inferlab`になる。
- 初期値のまま起動した場合、Keycloak管理者とrealm内admin userのpasswordはどちらも`admin`。
- Open-WebUI用Keycloak clientは`open-webui`、client secretは`OPEN_WEBUI_OIDC_CLIENT_SECRET`で上書きできる。
- OIKBはNextcloud volumeの`admin/files/oikb`をOpen-WebUI Knowledgeへ同期する。
- 既存のKeycloak realmがある環境では`--import-realm`だけではclient secretが更新されない場合がある。その場合はKeycloak管理consoleで`open-webui` clientのsecretを`OPEN_WEBUI_OIDC_CLIENT_SECRET`と一致させる。

## 1. 基本stackを起動する

```bash
# 初回設定に必要なprofileを起動する。
sudo docker compose --env-file .env --profile common --profile infra --profile inference --profile webui --profile storage up -d
```

期待結果:

- Keycloakが`http://${PUBLIC_HOST}:30001`で応答する。
- Open-WebUIが`http://${PUBLIC_HOST}:31100`で応答する。
- Nextcloudが`http://${PUBLIC_HOST}:31200`で応答する。
- OIKBが`http://${PUBLIC_HOST}:31201`で応答する。

失敗条件:

- `docker compose config --quiet`が失敗する。
- `keycloak`、`open-webui`、`nextcloud`、`oikb`のいずれかがunhealthyになる。

```bash
# 初回設定に必要な主要serviceの状態を確認する。
sudo docker compose --env-file .env --profile common --profile webui --profile storage ps keycloak open-webui nextcloud oikb
```

## 2. Keycloakへ初回ログインする

1. `http://${PUBLIC_HOST}:30001`を開く。
2. 管理consoleへ`admin` / `admin`でログインする。
3. 左上のrealm selectorで`inferlab`、または`.env`の`STACK_NAME`で指定したrealmを選ぶ。
4. `Users`で`admin` userが存在し、`admins`と`users` groupに所属していることを確認する。
5. `Clients`で`open-webui` clientが存在し、redirect URIに`http://${PUBLIC_HOST}:31100/oauth/oidc/callback`が含まれることを確認する。

期待結果:

- realm内の`admin` userでOpen-WebUIへOAuth loginできる。
- `open-webui` clientのsecretがOpen-WebUI containerの`OAUTH_CLIENT_SECRET`と一致している。

失敗条件:

- `inferlab` realmが存在しない。
- `open-webui` clientのsecretが一致しない。
- `groups` claimがID tokenまたはuser infoに含まれない。

## 3. Open-WebUIへKeycloakでログインする

1. `http://${PUBLIC_HOST}:31100`を開く。
2. `Keycloak`でログインする。
3. Keycloakのrealm内`admin` userで認証する。
4. Open-WebUIへ戻り、user menuからAPI keyを作成する。

期待結果:

- Open-WebUIにKeycloak認証userが作成される。
- API keyを1つ発行できる。

失敗条件:

- Keycloakログイン後にOpen-WebUIへredirectされない。
- Open-WebUIにAPI key作成画面が表示されない。

## 4. Open-WebUI Knowledgeを作成する

1. Open-WebUIで`Workspace`から`Knowledge`を開く。
2. 新しいKnowledgeを作成し、名前を`Nextcloud OIKB`などにする。
3. 作成後のURLまたは画面表示からKnowledge IDを控える。
4. `.env`に次の値を設定する。

```dotenv
OPEN_WEBUI_API_KEY=<Open-WebUIで作成したAPI key>
NEXTCLOUD_OPENWEBUI_KB_ID=<Open-WebUIで作成したKnowledge ID>
```

期待結果:

- OIKBがOpen-WebUI APIへ接続するためのAPI keyを持つ。
- OIKBが同期先Knowledge IDを参照できる。

失敗条件:

- `OPEN_WEBUI_API_KEY`が空のままになっている。
- `NEXTCLOUD_OPENWEBUI_KB_ID`が空のままになっている。

## 5. NextcloudにOIKB同期対象を用意する

1. `http://${PUBLIC_HOST}:31200`を開く。
2. `admin` / `admin`でログインする。
3. `oikb` folderを作成する。
4. `oikb/jsdf`と`oikb/dow`を作成する。
5. 同期対象PDFを`oikb/jsdf`または`oikb/dow`へ配置する。

期待結果:

- OIKB containerから`/nextcloud/data/admin/files/oikb`として読み取れる。
- `12-storage/oikb/oikb.yaml`の`source`と一致する。

失敗条件:

- Nextcloud上のfolderが`admin/files/oikb`以外に作成されている。
- PDF以外の不要なURL markerやサンプルfileが同期対象に残っている。

## 6. OIKBを再起動して同期する

```bash
# .envに設定したOpen-WebUI API keyとKnowledge IDをOIKBへ反映する。
sudo docker compose --env-file .env --profile storage up -d --force-recreate oikb
```

期待結果:

- OIKBがhealthyになる。
- OIKB logにNextcloud sourceのscanとOpen-WebUI Knowledgeへの同期が出る。
- Open-WebUIのKnowledgeにNextcloudへ配置したfileが登録される。

失敗条件:

- OIKB logにOpen-WebUI API認証エラーが出る。
- OIKB logにKnowledge ID未設定のエラーが出る。
- Open-WebUIのKnowledgeにfileが増えない。

```bash
# OIKBの同期logを確認する。
sudo docker logs --tail 200 inferlab-oikb
```

## 7. 再実行とrollback

再実行:

```bash
# OIKBだけを再作成して同期設定を再読み込みする。
sudo docker compose --env-file .env --profile storage up -d --force-recreate oikb
```

rollback:

```bash
# OIKBを停止してOpen-WebUI Knowledge同期を止める。
sudo docker compose --env-file .env --profile storage stop oikb
```

期待結果:

- 再実行時はOIKBが同じKnowledge IDへ同期する。
- rollback時はOIKBによる追加同期が停止する。

失敗条件:

- 再実行後も同じ認証エラーが続く。
- rollback後もOIKB containerがrunningのまま残る。
