# Keycloak 初期セットアップ

このドキュメントでは、このリポジトリで使用する Keycloak の初期セットアップ手順を説明します。

## 1. 必要なコンテナを起動する

`common`、`inference-ollama`、`openwebui` プロファイルを含めてサービスを起動します。

```bash
sudo docker compose \
  --profile common \
  --profile inference-ollama \
  --profile openwebui \
  up -d --force-recreate --remove-orphans
```

Keycloak が起動していることを確認します。

```bash
sudo docker ps | grep inferlab-keycloak
```

## 2. Keycloak 管理コンソールを開く

次の URL を開きます。

- `http://192.168.3.10:30000/admin/master/console/`

ブートストラップ管理者（`master` レルム）でログインします。

- ユーザー名: `admin`
- パスワード: `admin`

補足:

- ブートストラップ管理者は管理作業用です。
- Open WebUI のログインでは `master` ではなく `inferlab` レルムを使用します。

## 3. レルムとクライアントを確認する

対象レルムは `inferlab` です。

Keycloak でクライアント設定を開きます。

- レルム: `inferlab`
- クライアント: `open-webui`

必要な設定値:

- `Client authentication`: ON (confidential client)
- `Standard flow`: ON
- `Redirect URIs` に次を含める:
  - `http://localhost:31001/oauth/oidc/callback`
  - `http://192.168.3.10:31001/oauth/oidc/callback`
- `Web origins` に次を含める:
  - `http://localhost:31001`
  - `http://192.168.3.10:31001`

## 4. inferlab レルムに初回ログイン用ユーザーを作成する

`inferlab` にユーザーが存在しない場合、Open WebUI のログインは認証情報エラーで停止します。

`inferlab` レルムにユーザーを作成します（例）。

- ユーザー名: `owui`
- Enabled: ON
- Email verified: ON
- 設定するパスワード: `OwuiPass123!`
- 一時パスワード: OFF

推奨: 初回ユーザーに Required actions（プロフィール更新、パスワード更新など）が設定されている場合は解除します。

## 5. Open WebUI の OIDC エンドポイントを確認する

compose 設定では、Open WebUI のブラウザフロー用に公開側の Keycloak URL を使用します。

- `OPENID_PROVIDER_URL=http://192.168.3.10:30000/realms/inferlab/.well-known/openid-configuration`
- `OPENID_REDIRECT_URI=http://192.168.3.10:31001/oauth/oidc/callback`
- `WEBUI_URL=http://192.168.3.10:31001`

コンテナ設定の変更を反映します。

```bash
sudo docker compose \
  --profile common \
  --profile inference-ollama \
  --profile openwebui \
  up -d --force-recreate open-webui
```

## 6. ログイン動作を確認する

1. `http://192.168.3.10:31001/auth?redirect=%2F` を開く
2. `Continue with Keycloak` をクリックする
3. リダイレクト先が次の URL で始まることを確認する
   - `http://192.168.3.10:30000/realms/inferlab/protocol/openid-connect/auth`
4. 手順 4 で作成したユーザーでログインする

## 7. トラブルシューティング

### A. `Timeout when waiting for 3rd party check iframe message`

Keycloak のホスト名とアクセス元ホストの整合性を確認します。

- Keycloak と Open WebUI は同じホスト/IP（`192.168.3.10`）でアクセスする
- 同じブラウザセッションで `localhost` と LAN IP を混在させない

### B. リダイレクト先が `http://keycloak:8080/...` になる

原因: ブラウザ向けのプロバイダー URL が、コンテナ内部のホスト名に設定されています。

対応: Open WebUI が次を使用していることを確認します。

- `OPENID_PROVIDER_URL=http://192.168.3.10:30000/realms/inferlab/.well-known/openid-configuration`

### C. `/oauth/oidc/login` が `Internal Server Error` になる

Open WebUI のログで、`.well-known/openid-configuration` の取得が 404 になっていないか確認します。

例:

- `http://192.168.3.10:30000/realms/open-webui/.well-known/openid-configuration`

原因: `OPENID_PROVIDER_URL` のレルム名が誤っています。

対応: Open WebUI の `OPENID_PROVIDER_URL` を `inferlab` レルムに合わせます。

- `OPENID_PROVIDER_URL=http://192.168.3.10:30000/realms/inferlab/.well-known/openid-configuration`

変更後は Open WebUI コンテナを再作成します。

```bash
sudo docker compose \
  --profile common \
  --profile inference-ollama \
  --profile openwebui \
  up -d --force-recreate open-webui
```

### D. `The email or password provided is incorrect`

よくある原因:

- ユーザーが `inferlab` レルムに存在しない
- パスワードが一時パスワードになっている
- ユーザーに Required actions が残っている
- ユーザーが無効化されている

### E. `Account is not fully set up`

ユーザーのセットアップが完了していません。

対象ユーザーに対して次を確認します。

- 一時パスワードではないパスワードを設定する
- Required actions を解除する
- `enabled=true` および `emailVerified=true` になっていることを確認する

### F. `Uh-oh! This email is already registered.`

Keycloak のメールアドレスと同じメールアドレスのユーザーが Open WebUI 側に既に存在しています。

対応: Open WebUI で既存ユーザーと OAuth ログインをメールアドレスで統合できるようにします。

- `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`

変更後は Open WebUI コンテナを再作成します。

```bash
sudo docker compose \
  --profile common \
  --profile inference-ollama \
  --profile openwebui \
  up -d --force-recreate open-webui
```

### G. `アカウント承認待ち` と表示される

Open WebUI 側のユーザーロールが `pending` になっています。

手動承認する場合:

1. Open WebUI に管理者ユーザーでログインする
2. 管理者パネルのユーザー管理を開く
3. 対象ユーザーのロールを `user` または `admin` に変更する

新規ユーザーを自動承認する場合は、Open WebUI に次を設定します。

- `DEFAULT_USER_ROLE=user`

変更後は Open WebUI コンテナを再作成します。

## 8. 運用上の注意

現在の `realm-export.json` はレルムとクライアントを定義していますが、ユーザーは含んでいません。

そのため、初回デプロイ後に `inferlab` レルムのユーザー作成が必要です。
