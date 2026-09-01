# 20-owui

Open WebUI、Open Terminal、mcpo、SearXNG、OIKB、OIKB用RustFSをまとめたUI/Knowledge stack。

## 起動時初期化

このstackには次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `open-webui` | `open-webui/entrypoint_patch.sh`でDocling向けJSON設定をmultipart form用の文字列へ変換してからOpen WebUIを起動する。 |
| `mcpo` | Docker socket経由でllmwiki containerのstdio MCPを起動し、OpenAPIとしてOpen WebUIへ公開する。 |
| `oikb-rustfs-init` | Compose内のinit commandでRustFSがhealthyになった後、`oikb-bucket`が無ければ作成する。 |
| `oikb` | APIとsource状態を公開する。内蔵schedulerは無効で、同期は外部scriptが逐次実行する。 |

Open WebUIのKeycloak連携は、`OAUTH_CLIENT_SECRET`とKeycloak側`open-webui` client secretの一致が前提になる。

llmwiki連携では、`mcpo`がDocker socketへアクセスして`${STACK_NAME}-llmwiki`内でMCPプロセスを起動する。Docker socketへアクセスできるcontainerはホスト上のDockerを操作できるため、信頼できる設定とイメージだけを使用すること。

## 起動

### Open WebUI stackのみを起動

```bash
# Open WebUI stackを起動する。
sudo docker compose --env-file .env --profile owui up -d
```

期待結果:

- `searxng`、`open-terminal`、`mcpo`がhealthyになる。
- `open-webui`が`http://${PUBLIC_HOST}:32000`で応答する。
- `oikb-rustfs-init`が正常終了する。
- `oikb`が`http://${PUBLIC_HOST}:32001`で応答する。

失敗条件:

- `open-webui/entrypoint_patch.sh`がDocling設定を生成できない。
- RustFS bucket作成が認証エラーになる。
- OIKB imageのbuildまたはAPI起動に失敗する。

### llmwiki連携を含めて起動

llmwikiのtoolをOpen WebUIから使用する場合は、llmwiki profileも同時に起動する。

```bash
# Open WebUIとllmwikiを起動し、mcpo経由のMCP接続を有効にする。
sudo docker compose --env-file .env --profile owui --profile llmwiki up -d
```

期待結果:

- `mcpo`の`/llmwiki/openapi.json`がllmwikiのtool定義を返す。
- Open WebUIのtool server一覧で`llmwiki`接続が有効になる。

失敗条件:

- `${STACK_NAME}-llmwiki`が起動しておらず、mcpoがMCPプロセスを開始できない。
- Docker socketへのアクセスが拒否される。
- llmwikiに必要なLiteLLMまたはembeddingの認証情報が不足している。

## 確認手順

```bash
# owui profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile owui ps

# Open WebUIのhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32000/health" >/dev/null

# OIKBのhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32001/health" >/dev/null

# mcpoが公開するllmwikiのOpenAPI定義を確認する。
curl -fsS -H "Authorization: Bearer ${MCPO_API_KEY:-sk-mcpo-api-secret-key}" \
  "http://${PUBLIC_HOST:-localhost}:32004/llmwiki/openapi.json" >/dev/null
```

期待結果:

- `open-webui`と`oikb`がhealthyになる。
- `oikb-rustfs-init`が`exited (0)`になる。
- RustFS上に`oikb-bucket`が存在する。
- llmwikiのOpenAPI定義を取得できる。

失敗条件:

- `oikb-rustfs-init`が繰り返し失敗する。
- Open WebUIのOAuth loginがKeycloak client secret不一致で失敗する。
- OIKBがNextcloudまたはRustFS sourceを読み取れない。
- mcpoからllmwikiのMCPプロセスを起動できない。

## 再初期化

OIKB用RustFS bucketを作り直す場合は、OIKB用RustFS volumeを削除する。

```bash
# owui stackを停止する。
sudo docker compose --env-file .env --profile owui down

# OIKB用RustFSの永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_oikb-rustfs-data"

# owui stackを再作成し、bucket作成を再実行する。
sudo docker compose --env-file .env --profile owui up -d
```

期待結果:

- RustFS data volumeが再作成される。
- `oikb-rustfs-init`が`oikb-bucket`を再作成する。

失敗条件:

- volumeが使用中で削除できない。
- OIKBが既存Knowledge IDの対象sourceと不整合になる。

## Knowledge Baseの定期保守

保守scriptのlog messageは英語で出力し、terminal実行時は`DEBUG`、`INFO`、`WARNING`、`ERROR`、`CRITICAL`のlevel名を色付きで表示する。ANSI colorを無効にする場合は`NO_COLOR`環境変数を設定する。

### 処理停止ファイルの削除

`oikb/remove_openwebui_stuck_files.py`は、OIKBのhealthと同期履歴から現在登録されているKnowledge Baseを調査し、Open WebUIで`pending`または`processing`のまま1時間以上更新されていないfileを検出する。Knowledge IDは`--knowledge-id`で明示してもよい。

scriptはrepository rootの`.env`を起動時に読み込む。processへ設定済みの環境変数とcommand line optionは`.env`より優先される。

既定ではdry-runになり、fileを削除しない。

```bash
# 1時間以上更新されていない処理停止fileを表示する。
python3 20-owui/oikb/remove_openwebui_stuck_files.py
```

期待結果:

- 処理停止fileのKnowledge ID、file ID、statusがwarning logへ出力される。
- Open WebUIのfile、Knowledge関連、vectorは変更されない。

失敗条件:

- API keyが未設定でscriptが終了code 2を返す。
- Open WebUIまたはOIKBへ接続できず、scriptが終了code 1を返す。

dry-run結果を確認した後、`--delete`を指定すると対象fileを削除する。

```bash
# dry-runで確認した処理停止fileと関連vectorを削除する。
python3 20-owui/oikb/remove_openwebui_stuck_files.py --delete
```

期待結果:

- 対象fileごとに削除完了logが出力される。
- Open WebUI APIがfile本体、Knowledge関連、関連vectorを削除する。

失敗条件:

- 削除権限がなくOpen WebUI APIがerrorを返す。
- 削除対象のstorageまたはvector cleanupに失敗する。

削除したfileは復元できない。rollbackが必要な場合は、元sourceを保持した状態でOIKB同期を再実行する。

### OIKB同期の定期trigger

`oikb/trigger_oikb_syncs.py`は、`.env`の`OIKB_SOURCE_ORDER`に指定した順でsourceを1つずつ同期する。各sourceで次をすべて確認してから、次のsourceをtriggerする。

1. OIKBの今回の同期が`success`で終了する。
2. OIKBのhistoryに今回の同期結果が保存される。
3. 今回のOpen WebUI fileがすべて`completed`になる。
4. fileがKnowledge Baseへlinkされ、pending fileが0件になる。

OIKB内蔵schedulerが各sourceを並列起動しないよう、custom imageで内蔵schedulerを無効化している。変更後はOIKB imageを再buildする。

```bash
# 外部scheduler専用のOIKB imageをbuildし、OIKBだけ再作成する。
sudo docker compose --env-file .env --profile owui up -d --build --no-deps oikb
```

期待結果:

- OIKBの`GET /health`が各sourceに`kb_id`と`idle`状態を返す。
- OIKBを再起動しても、scriptがtriggerするまでsource同期は始まらない。

失敗条件:

- OIKBのhealth responseに`kb_id`がなく、scriptがimageの再buildを求めて終了する。

repository rootの`.env`はscript起動時に自動で読み込まれる。processへ設定済みの環境変数とcommand line optionは`.env`より優先される。実行間隔は`OIKB_TRIGGER_INTERVAL_SECONDS`または`--interval-seconds`で変更できる。

```bash
# OIKB_SOURCE_ORDERの順に同期し、全source完了後に1時間待つ。
python3 20-owui/oikb/trigger_oikb_syncs.py
```

期待結果:

- sourceごとにOIKB trigger、Open WebUI登録完了のlogが指定順で出力される。
- 全sourceの完了後から3600秒後に次の周期が始まる。

失敗条件:

- OIKB API keyまたはOpen WebUI API keyが未設定でscriptが終了code 2を返す。
- OIKB同期、Open WebUI file処理、link、またはpending解消が失敗すると、後続sourceをtriggerせず次周期まで待つ。
- 同期前から対象Knowledge Baseにpending fileがある場合は、前回処理と混同しないよう失敗する。

動作確認では`--once`を指定し、1周期だけ実行できる。

```bash
# OIKB_SOURCE_ORDERの全sourceを1回だけ逐次同期する。
python3 20-owui/oikb/trigger_oikb_syncs.py --once
```
