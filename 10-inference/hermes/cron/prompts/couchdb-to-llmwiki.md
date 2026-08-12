# CouchDB to LLMwiki sync

## 目的

CouchDBの変更をLLMwikiへ取り込み、Hermes-AgentがMCP経由で参照できるMarkdown知識に更新する。専用sync workerは作らず、Hermes-Agentのcron実行だけで完結させる。

## 入力

- `COUCHDB_URL`: CouchDBのbase URL。
- `COUCHDB_USER`: CouchDBのuser名。
- `COUCHDB_PASSWORD`: CouchDBのpassword。
- `LLM_WIKI_SPACE_PATH`: llm-wikiのspace path。通常は`/wikis/inferlab`。
- `LLM_WIKI_MCP_URL`: llm-wiki MCP endpoint。通常は`http://llm-wiki:8080/mcp`。

## 手順

1. `COUCHDB_URL`、`COUCHDB_USER`、`COUCHDB_PASSWORD`、`LLM_WIKI_SPACE_PATH`が存在することを確認する。
2. `/opt/data/cron/state/couchdb-to-llmwiki.json`をcheckpointとして読む。存在しない場合は空の状態として扱う。
3. CouchDBの`/_all_dbs`を取得し、`_users`、`_replicator`、`_global_changes`などのsystem databaseを除外する。
4. 各databaseについて、checkpointの`last_seq`以降を`/{db}/_changes?include_docs=true&limit=50&since={last_seq}`で取得する。checkpointがない場合は`since=0`を使う。
5. 削除済みdocument、attachment本体、binaryや巨大fieldを取り込まない。`password`、`secret`、`token`、`key`を含むfield名は値を`[REDACTED]`に置き換える。
6. 各databaseの概要を`$LLM_WIKI_SPACE_PATH/couchdb/{database}/README.md`へ書く。
7. 変更があったdocumentは、1件ごとに`$LLM_WIKI_SPACE_PATH/couchdb/{database}/documents/{doc-id}.md`へ要約を書く。本文には少なくともdocument ID、更新時刻、主要field、Hermesが再利用しやすい短い要約を含める。
8. llm-wiki MCP toolが利用できる場合は、作成または更新したpageをMCPでも確認する。MCPが使えない場合は、llm-wikiの`--watch`がMarkdown fileを取り込む前提でfile更新を完了扱いにする。
9. file更新が成功したdatabaseだけ、checkpointの`last_seq`を今回取得した`last_seq`へ進める。
10. 変更がなかった場合は`[SILENT]`だけで終了する。変更があった場合は、更新したdatabase名、document件数、失敗したdatabase名を短く報告する。

## 制約

- 外部networkへ送信しない。
- CouchDBのcredentialやdocument内secretを出力しない。
- 1回の実行で無理に全件を処理しない。大量変更がある場合は次回cronへ残す。
- LLMwiki以外の永続化先を新設しない。
