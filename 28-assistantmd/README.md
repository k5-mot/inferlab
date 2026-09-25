# 28-assistantmd

Assistant.md v0.8.1を、固定したupstream commitからbuildしてComposeでhostする。

## 構成

- Web UIは`http://${PUBLIC_HOST}:32800/`で公開する。
- sourceはv0.8.1のcommitへ固定する。
- browser toolを含む制限付きexecution modeを使用し、advanced shellは起動しない。
- vaultは`assistantmd-data`へ、database、設定、logは`assistantmd-system`へ保存する。
- 初回起動時に`Workspace` vaultを作成する。
- owner token認証を使用する。

`ASSISTANTMD_SECRETS_KEY`と`ASSISTANTMD_AUTH_SECRET`のsample値は開発用である。LANへ公開する前に、環境固有の値へ変更しなければならない（MUST）。Internetへ直接公開してはならず、HTTPS reverse proxyまたはVPNを前段に配置しなければならない（MUST）。

## 初回設定

repository rootの`.env`へ、異なる2つのsecretを設定する。

```bash
# credential暗号化用の32 byte keyを生成する。
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='

# owner token認証用のsecretを生成する。
openssl rand -hex 32
```

生成した値を`.env`へ保存する。

```dotenv
ASSISTANTMD_SECRETS_KEY=<最初のcommandで生成した値>
ASSISTANTMD_AUTH_SECRET=<2番目のcommandで生成した値>
```

`ASSISTANTMD_SECRETS_KEY`と`assistantmd-system` volumeは、復元時に同じ世代の組み合わせが必要になる。別々の安全な場所へbackupしなければならない（MUST）。

## 起動

repository rootで実行する。初回buildではupstream sourceからPython dependency、CSS、Chromiumを含むimageを作成するため時間がかかる。

```bash
# Assistant.mdをbuildして起動する。
sudo docker compose --env-file .env --profile assistantmd \
  up -d --build assistantmd
```

期待結果:

- `assistantmd-init`が正常終了する。
- `assistantmd`がhealthyになる。
- `http://${PUBLIC_HOST}:32800/`にowner login画面が表示される。

失敗条件:

- hostの`32800`が他processと競合している。
- `ASSISTANTMD_SECRETS_KEY`がURL-safe Base64で表した32 byte keyではない。
- `ASSISTANTMD_AUTH_SECRET`が32文字未満である。
- image buildに必要なnetwork、memory、またはdiskが不足する。

## LoginとLiteLLM設定

1. `http://${PUBLIC_HOST}:32800/`を開く。
2. `.env`の`ASSISTANTMD_AUTH_SECRET`をowner tokenとして入力する。
3. `System` → `Secrets`で`OPENAI_API_KEY`へ`.env`の`LITELLM_MASTER_KEY`と同じ値を登録する。
4. `System` → `Model Providers`でOpenAI互換providerを作成し、base URLを`http://litellm:4000/v1`へ設定する。
5. providerが返すmodel一覧から利用するmodelを有効化する。

`http://litellm:4000/v1`はDocker network内のURLであり、host browserから直接開くURLではない。共有画面やscreenshotへowner tokenまたはAPI keyを含めてはならない（MUST NOT）。

## 検証

```bash
# Assistant.mdのcontainer状態とhealthcheckを確認する。
sudo docker compose --env-file .env --profile assistantmd ps assistantmd

# 認証不要のhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32800/api/health"

# 起動logに設定errorがないことを確認する。
sudo docker compose --env-file .env --profile assistantmd logs --tail=100 assistantmd
```

期待結果:

- `assistantmd`が`healthy`と表示される。
- health endpointが`status: healthy`を含むJSONを返す。
- login後に`Workspace` vaultを選択できる。

失敗条件:

- `assistantmd-init`がvolumeの所有権を設定できない。
- health endpointがHTTP 503を返す。
- container logにauthenticationまたはsecret encryptionの設定errorが出る。

## 停止と再初期化

```bash
# Assistant.md containerを停止する。永続dataはvolumeへ残る。
sudo docker compose --env-file .env --profile assistantmd stop assistantmd

# Assistant.md containerを削除する。永続dataはvolumeへ残る。
sudo docker compose --env-file .env --profile assistantmd rm -f assistantmd
```

完全な再初期化では、vault、会話、設定、credentialを復元できなくなる。必要なdataをbackupしてから実行しなければならない（MUST）。

```bash
# data消失を理解した場合に限り、Assistant.mdの永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_assistantmd-data" "${STACK_NAME}_assistantmd-system"
```

期待結果:

- 次回起動時に空の`Workspace` vaultとsystem状態が作成される。

失敗条件:

- Assistant.md containerが残っているためvolumeを削除できない。
- backupなしで削除し、以前のvault、設定、credentialを復元できない。

rollbackする場合は、停止中に取得した2つのvolume backupと、同じ世代の`ASSISTANTMD_SECRETS_KEY`を復元する。

## References

- [Assistant.md v0.8.1](https://github.com/DodgyBadger/Assistant.md/releases/tag/v0.8.1)
- [Assistant.md Installation](https://github.com/DodgyBadger/Assistant.md/blob/v0.8.1/docs/setup/installation.md)
- [Assistant.md Security Considerations](https://github.com/DodgyBadger/Assistant.md/blob/v0.8.1/docs/setup/security.md)
- [Assistant.md Architecture Overview](https://github.com/DodgyBadger/Assistant.md/blob/v0.8.1/docs/development/architecture.md)
