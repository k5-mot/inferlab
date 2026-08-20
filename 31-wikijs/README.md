# 31-wikijs

Wiki.jsと依存するPostgreSQLだけを提供するWiki stackである。

## 構成

- `wikijs`: Wiki.js 2.5.314本体。
- `wikijs-postgres`: Wiki.jsの設定とpageを保持するPostgreSQL。

初期設定用containerやAPI key発行用sidecarは配置しない。Wiki.jsの初期設定は本体のsetup wizardで行い、OpenKB連携用API keyは管理画面で発行する。

## 起動手順

```bash
# Wiki.jsとPostgreSQLを起動する。
sudo docker compose --env-file .env --profile wikijs up -d
```

期待結果:

- `wikijs-postgres`と`wikijs`がhealthyになる。
- Wiki.jsを`http://${PUBLIC_HOST}:33100`で表示できる。
- 未初期化時はsetup wizard、初期化済みならWiki画面が表示される。

失敗条件:

- `wikijs-postgres`がhealthyにならない。
- `wikijs` logにdatabase接続失敗が記録される。
- `WIKIJS_DB_PASSWORD`を変更したのに既存volume側のpasswordと一致しない。

## 初期設定

ブラウザで`http://${PUBLIC_HOST}:33100`を開き、管理者mail address、password、site URLを設定する。site URLには外部から利用する`http://${PUBLIC_HOST}:33100`を指定する。

OpenKB連携では管理画面のAPI設定を有効化し、次の2用途のAPI keyを分けて発行することを推奨する。

| 用途 | 必要な操作 |
| --- | --- |
| source reader | Human Wiki path配下のpage listとsource読取 |
| LLM Wiki publisher | LLM Wiki path配下のpage作成・更新・source読取 |

期待結果:

- `/graphql`がGraphQL requestを受け付ける。
- Human WikiとLLM Wikiに異なるpath prefixを設定できる。

失敗条件:

- APIが無効でAPI keyを利用できない。
- API keyのpage ruleが対象pathを許可していない。
- Human WikiとLLM Wikiに同じpath prefixを設定する。

## 確認手順

```bash
# Wiki.js profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile wikijs ps

# Wiki.js HTTP endpointの応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:33100/" >/dev/null
```

期待結果:

- `wikijs`と`wikijs-postgres`がhealthyである。
- HTTP endpointが成功responseを返す。

失敗条件:

- いずれかのcontainerが再起動を繰り返す。
- HTTP endpointが5xx responseを返す。

## 再初期化

再初期化ではPostgreSQL volumeを削除する。既存Wiki内容と設定を失うため、実行前にbackupを取得すること。

```bash
# Wiki.js stackを停止する。
sudo docker compose --env-file .env --profile wikijs down

# Wiki.jsの永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_wikijs-postgres-data"

# Wiki.js stackを再作成する。
sudo docker compose --env-file .env --profile wikijs up -d
```

期待結果:

- setup wizardが再表示される。

失敗条件:

- volumeが使用中で削除できない。
- 事前backupを取得していない状態で既存dataが必要になる。

## References

- [Wiki.js Docker installation](https://docs.requarks.io/install/docker)
- [Wiki.js GraphQL API](https://docs.requarks.io/dev/api)
- [Wiki.js releases](https://github.com/requarks/wiki/releases/tag/v2.5.314)
