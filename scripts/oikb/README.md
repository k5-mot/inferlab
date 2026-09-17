# OIKB保守CLI

`oikb_sync.py`は、OIKB sourceの逐次同期とOpen WebUI Knowledge Base（KB）の停止file削除を行う。repository rootから実行する。

## 環境変数

CLIはrepository rootの`.env`を起動時に読み込む。processへ設定済みの環境変数は`.env`より優先される。API URLとcredentialはcommand line引数では受け取らず、次の環境変数から取得する。

```dotenv
OPEN_WEBUI_API_URL=http://localhost:32000
OPEN_WEBUI_API_KEY=<Open WebUI API key>
OIKB_API_URL=http://localhost:32001
OIKB_API_KEY=<OIKB API key>
OIKB_SOURCE_ORDER=nextcloud-documents,rustfs-documents
```

`OPEN_WEBUI_API_URL`と`OIKB_API_URL`を省略した場合は、上記のlocalhost URLを使用する。

## helpの表示

```bash
# 利用可能なsubcommandを表示する。
python3 scripts/oikb/oikb_sync.py --help

# triggerのoptionを表示する。
python3 scripts/oikb/oikb_sync.py trigger --help

# deleteのoptionを表示する。
python3 scripts/oikb/oikb_sync.py delete --help
```

期待結果:

- `trigger`と`delete`がsubcommandとして表示される。
- 両subcommandに`--dry-run`が表示される。

失敗条件:

- Python dependencyを読み込めず、helpを表示する前に終了する。

## 未同期fileの確認

`trigger --dry-run`は、`OIKB_SOURCE_ORDER`の各sourceについてOIKBの差分計算だけを実行する。追加または更新が必要なfileを`Unsynced OIKB file`としてlogへ記録し、Open WebUIは変更しない。

```bash
# 全sourceの未同期fileを変更せずに確認する。
python3 scripts/oikb/oikb_sync.py trigger --dry-run
```

期待結果:

- 未同期fileごとにsource名、`added`または`modified`、source内pathが表示される。
- OIKB healthのsource状態が`idle`へ戻る。
- Open WebUIのfileとKBは変更されない。

失敗条件:

- OIKB2 imageが古く、dry-run responseにfile詳細がない。
- OIKBがsource manifestまたはOpen WebUIとの差分を取得できない。

## KBの逐次同期

`trigger`は、`OIKB_SOURCE_ORDER`または繰り返し指定した`--source`の順でKBを1つずつ処理する。1 KBについて次をすべて確認してから、次のKBをtriggerする。

1. OIKBの同期が`success`で終了する。
2. OIKBのhistoryに今回の同期結果が保存される。
3. KB内の全fileが`completed`になる。
4. 今回のfileがKBへlinkされ、pending fileが0件になる。

```bash
# OIKB_SOURCE_ORDERの全KBを1回だけ逐次同期する。
python3 scripts/oikb/oikb_sync.py trigger
```

期待結果:

- 1 KBの全fileが`completed`になるまで次のKBはtriggerされない。
- `Ctrl+C`後に再実行した場合、実行中のsourceへ再接続して待機を継続する。
- file登録が失敗した場合は、失敗fileを削除して同じfileを1回retryする。
- OIKB Docker logに`OIKB2 processing file`と`OIKB2 registered file`がfileごとに同じ順で表示される。
- 全KBの完了後、CLIが終了code 0で終了する。

失敗条件:

- API key、source名、またはKnowledge IDが不正である。
- OIKB同期、Open WebUI file処理、KBへのlink、またはpending解消が失敗する。
- 対象KBのfileがretry後も失敗し、同じKBの次fileと後続KBを開始せず終了する。

Composeの`oikb-scheduler` serviceは`--watch`を指定したCLIを常駐実行する。全KBの完了後、`OIKB_TRIGGER_INTERVAL_SECONDS`の既定値3,600秒を待って次の同期周期を開始する。

```bash
# external schedulerの稼働状態を確認する。
sudo docker compose --env-file .env --profile owui --profile nextcloud ps oikb-scheduler
```

期待結果:

- `oikb-scheduler`が`healthy`になる。
- 同期失敗後もserviceが終了せず、次の周期で再試行する。

失敗条件:

- `oikb-scheduler`が起動しない、または`unhealthy`になる。
- `OPEN_WEBUI_API_KEY`、`OIKB_API_KEY`、またはKnowledge IDが未設定で同期が失敗する。

## 停止fileの確認と削除

`delete`は全KBのfileを調査し、statusが`pending`または`failed`のfileだけを対象にする。`processing`と`completed`は削除しない。最初に`--dry-run`で対象を確認する。

```bash
# 全KBの削除候補を変更せずにlogへ記録する。
python3 scripts/oikb/oikb_sync.py delete --dry-run
```

期待結果:

- 対象fileごとにKnowledge ID、file ID、status、file名が表示される。
- `processing`と`completed`は表示されず、Open WebUIは変更されない。

失敗条件:

- Open WebUIまたはOIKBへ接続できない。
- API keyの権限不足により全fileまたはKnowledge IDを取得できない。

確認した対象を削除する。

```bash
# 全KBのpendingとfailed fileを削除する。
python3 scripts/oikb/oikb_sync.py delete
```

期待結果:

- dry-runと同じ選択条件のfileだけが削除される。
- file本体、Knowledge関連、関連vectorの削除完了がlogへ表示される。

失敗条件:

- dry-run後に対象のstatusが変化した。
- Open WebUIのfileまたはvector削除APIがerrorを返した。

削除したfileは復元できない。復旧が必要な場合は元sourceを保持した状態で`trigger`を再実行する。

## Embeddingモデル変更後の再index

Embeddingモデルを変更した場合、既存のKnowledge Baseは新しいmodelで再indexする。再indexはKnowledge Baseごとの既存vector collectionを削除し、現在のchunk設定とembedding modelで全fileを再処理する。Knowledge Baseへ属さないchat添付fileは対象外とする。

```bash
# 既存の全Knowledge Baseを現在のembedding modelで再indexする。
sudo docker compose --env-file .env --profile owui exec -T oikb python -c "import os,urllib.request; r=urllib.request.Request(os.environ['OPEN_WEBUI_URL'].rstrip('/')+'/api/v1/knowledge/reindex',data=b'',headers={'Authorization':'Bearer '+os.environ['OPEN_WEBUI_API_KEY']},method='POST'); print(urllib.request.urlopen(r,timeout=21600).read().decode())"
```

期待結果:

- commandが`true`を返す。
- Open WebUI logに`Reindexing completed`が記録される。
- Knowledge Base検索が新しいembedding modelで結果を返す。

失敗条件:

- commandがHTTP errorまたはtimeoutで終了する。
- Open WebUI logに`Failed to process`が記録される。
- reindex後のKnowledge Base検索が結果を返さない。

rollback:

- reindexにatomicなrollbackはない。失敗した場合は以前のembedding modelへ戻し、modelのhealthを確認してから同じcommandを再実行する。

## References

- [OIKB v0.4.0 daemon](https://github.com/open-webui/oikb/blob/v0.4.0/src/oikb/daemon.py)
- [OIKB v0.4.0 sync history](https://github.com/open-webui/oikb/blob/v0.4.0/src/oikb/history.py)
- [Open WebUI: Retrieval-Augmented Generation](https://docs.openwebui.com/features/chat-conversations/rag/)
- [Open WebUI v0.11.3 knowledge router](https://github.com/open-webui/open-webui/blob/v0.11.3/backend/open_webui/routers/knowledge.py)
