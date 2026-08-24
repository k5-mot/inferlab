# LLMWikiのCouchDBデータソース調査（2026-08-25）

## 結論

`40-obsidian`のCouchDBをLLMWikiへ取り込むには、Self-hosted LiveSyncの保存形式をread-onlyで復元し、`llm-wiki-compiler`の`ingestText`へ渡すsource adapterが適している。双方向同期toolをLLMWiki containerへ組み込む必要はない。

データソース追加を見越し、runnerとschedulerはCouchDB固有形式を扱わない。source adapter registryをseamとし、既存のURL/file inputとCouchDBを別adapterにする。新しいデータソースは同じinterfaceの背後へ追加できる。

## 調査対象のデータ

現行`obsidian` databaseには、Markdown親documentと本文を分割したleaf chunkが保存されている。親documentは`type=plain`、note path、順序付き`children`を持ち、各leafは`type=leaf`と平文`data`を持つ。

調査時点では307件のMarkdown親documentがあり、118件が非削除、189件が削除済みだった。非削除documentには通常noteだけでなく、Self-hosted LiveSyncが`ix:` pathへ保存したObsidian設定、plugin data、plugin本体、theme snapshotも含まれていた。`.obsidian`など`.`で始まるpath segment、`config.yaml`の`exclude_path_prefixes`、Markdown以外、空本文は対象外にする。初期設定では`ix:`を除外する。

## 採用方式

CouchDBの`/{database}/_all_docs?include_docs=true`から一貫したsnapshotを取得し、親documentの`children`順にleaf chunkを連結する。復元した各noteはpathをtitle、CouchDB document URLをprovenanceとして`ingestText`へ渡す。

adapterはdocument IDとupstreamが返すsource file名のmanifestを保持する。次回snapshotに存在しないdocumentは、manifestで所有を確認できるsource fileだけを削除する。これにより、別adapterが作成したsourceを誤って削除しない。

## 拡張性

source adapterのinterfaceは、正規化済みsource設定とproject root、credential環境変数だけを受け取り、同期完了を返す。CouchDBのchunk復元、認証、snapshot上限、manifest管理はadapterのimplementationへ隠す。

現在は次の2つのadapterを登録する。

- Input Adapter: URLまたはfileをupstream CLIの`ingest`へ渡す。
- CouchDB Adapter: LiveSync snapshotを復元し、SDKの`ingestText`へ渡す。

将来GitLabやNextcloudを追加する場合も、schedulerやLLMWiki clientを変更せず、設定schemaとadapterを追加する。sourceごとの増分token、pagination、rate limitは各adapter内へ閉じ込める。

## セキュリティと失敗時動作

CouchDB URLへcredentialを埋め込まず、usernameとpasswordは環境変数から取得する。HTTP error、認証失敗、不正なJSON、欠落leaf chunk、document上限超過は同期失敗にする。

取得と復元が完了するまで既存manifestを置換しない。source更新途中のfilesystem errorはjob failureとして記録し、compile-on-ingestを実行しない。完全なtransactionではないため、再実行によって同じsnapshotへ収束させる。

## References

- [Apache CouchDB `_all_docs`](https://docs.couchdb.org/en/stable/api/database/bulk-api.html#db-all-docs)
- [llm-wiki-compiler README](https://github.com/atomicstrata/llm-wiki-compiler/blob/main/README.md)
- [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)
- [livesync-bridge](https://github.com/vrtmrz/livesync-bridge)
