# LLM Wiki

`llm-wiki-compiler` 1.1.0 をKnowledge Compiler、MCP server、read-only Viewerに使用する。実行環境は、upstreamのViewerとMCPを提供する`llmwiki` containerと、adapterおよび`ingest -> compile -> lint -> eval` pipelineを実行する`llmwiki-ingester` containerに分離する。両containerは`llmwiki-project` named volumeだけを共有する。

OpenKB、Wiki.js publish、OKF importは使用しない。OKF importは完成済みpageを`wiki/`へ直接書き、adapterとcompilerの`sources/`境界を迂回するためである。OKF exportはupstream CLIまたはMCPの`export_okf`をそのまま使用できる。

source-system固有処理は`llmwiki-ingester`のsource adapter interfaceの背後へ置く。adapterはupstreamの[`sources/` Input Contract](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/SOURCES_CONTRACT.md)に従うMarkdownを共有volumeの`sources/`へ生成し、以降のcompile、lint、evalはupstream CLIへ委譲する。

## 設定

すべての運用設定は [config.yaml](config.yaml) に置く。credential の値だけは環境変数で渡し、`provider.credential_env` と `provider.embedding.credential_env` には参照する環境変数名を指定する。既定の embedding model は inference stack の TEI model `cl-nagoya/ruri-v3:310m` を LiteLLM 経由で使用する。TEI の request 上限に合わせ、embedding batch sizeは2とする。

設定は container 起動時に一度だけ読み込む。変更後は container を再起動する。

source 共通設定へ source 別設定を上書きする例は次のとおり。

```yaml
defaults:
  ingest:
    enabled: false
    schedule: "0 * * * *"
    timeout_seconds: 600

sources:
  - id: engineering-handbook
    adapter: input
    input: https://example.internal/engineering/handbook
    ingest:
      enabled: true
      schedule: "*/15 * * * *"
```

現在の設定は`40-obsidian`のCouchDB `obsidian` databaseを6時間ごとに同期し、同期成功後に増分compileする。LiveSyncの非削除Markdown親documentだけを対象に、`children`順でleaf chunkを復元する。hidden path、Markdown以外、空本文はWikiへ取り込まない。前回manifestにだけ残るsource fileはsnapshot同期時に削除する。

`title_strategy`はCouchDB document pathからLLMWiki source titleを生成する方式を指定する。`path`は従来どおりpathをそのまま使用する。`hierarchy`は末尾の`.md`を除去し、すべてのfolder名とnote名を空白で連結する。階層名の重複は除去しないため、`AWS/AWS CLF/事前テスト.md`は`AWS AWS CLF 事前テスト`になる。

compile成功後はIngesterが共有volumeの`.llmwiki/viewer-generation`を更新する。`llmwiki` containerは`viewer.reload_poll_seconds`間隔でmarkerを確認し、新しいfilesystem snapshotでViewerを再起動する。lintとevalはdiagnosticとして実行し、初期MVPではpipelineの公開可否を判定するvalidation gateには使用しない。

CouchDBのcredentialは値ではなく参照環境変数名を設定する。

```yaml
sources:
  - id: obsidian-couchdb
    adapter: couchdb
    url: http://couchdb:5984
    database: obsidian
    username_env: COUCHDB_USERNAME
    password_env: COUCHDB_PASSWORD
    title_strategy: hierarchy
    exclude_path_prefixes:
      - "ix:"
    max_documents: 1000
    ingest:
      enabled: true
      schedule: "0 */6 * * *"
```

## 開発

```bash
# RuntimeとIngesterの依存関係を固定lockfileから導入する。
pnpm --dir 41-llmwiki install --ignore-workspace --frozen-lockfile

# TypeScriptの型検査を実行する。
pnpm --dir 41-llmwiki typecheck

# buildとunit testを実行する。
pnpm --dir 41-llmwiki test
```

期待結果:

- dependency install が終了 code 0 で完了する。
- type check が error なしで完了する。
- unit test がすべて成功する。

失敗基準:

- lockfile 差分、型 error、test failure のいずれかがある場合は変更を完了扱いにしてはならない。

## 起動

```bash
# RuntimeとIngester imageをbuildして2 containerを起動する。
docker compose --profile llmwiki up -d --build llmwiki llmwiki-ingester

# RuntimeとIngesterの状態を確認する。
docker compose ps llmwiki llmwiki-ingester

# upstreamが認識しているproject状態を確認する。
docker compose exec -w /data/llmwiki llmwiki llmwiki status
```

期待結果:

- `llmwiki` containerがhealthyになり、`llmwiki-ingester` containerがrunningになる。
- `http://localhost:34100` で upstream viewer を表示できる。
- IngesterへCouchDB同期とcompileのscheduled jobが登録される。

失敗基準:

- config schema、cron、timezone、必要credentialが不正な場合、該当containerは起動に失敗する。
- viewer または proxy が起動できない場合、container は healthy にならない。

## MCP

`llmwiki serve`はTCP serverではなくstdio transportである。MCP clientはRuntime container内へ`docker exec -i`し、接続ごとにstdio serverを起動する。

```json
{
  "mcpServers": {
    "llmwiki": {
      "command": "docker",
      "args": [
        "exec",
        "-i",
        "inferlab-llmwiki",
        "node",
        "/app/dist/serve.js"
      ]
    }
  }
}
```

Runtime wrapperは`config.yaml`からprovider、model、project rootを読み、upstream `llmwiki serve --root /data/llmwiki`へstdioをそのまま接続する。

## 手動確認

```bash
# CouchDB snapshotをsourceへ同期し、compile、lint、evalを順に実行する。
docker compose exec llmwiki-ingester node /app/dist/main.js ingest obsidian-couchdb

# config.yamlのprovider設定でone-shot compile、lint、evalを実行する。
docker compose exec -w /data/llmwiki llmwiki-ingester node /app/dist/main.js compile

# upstream機能で現在WikiのOKF bundleを生成する。
docker compose exec -w /data/llmwiki llmwiki llmwiki export --target okf --out artifacts/okf
```

期待結果:

- CouchDB同期logに対象document数と`created`、`updated`、`unchanged`、`removed`が記録される。
- `sources/`へMarkdown sourceが生成され、compile後に`wiki/`が更新される。
- `.llmwiki/last-lint.json`と`.llmwiki/eval/history.jsonl`が更新される。
- generation marker検知後に`http://localhost:34100`で生成Wikiを表示できる。
- `artifacts/okf`へOKF bundleが生成される。

失敗基準:

- CouchDBの認証、HTTP応答、LiveSync chunk参照のいずれかが不正な場合、snapshotを成功扱いにしてはならない。
- 対象Markdown数が`max_documents`を超えた場合、同期を中止する。

Runtime containerでupstream `llmwiki compile`を直接実行した場合はgeneration markerが更新されない。定常運用と手動pipelineは`llmwiki-ingester`を使用する。

## Rollback

```bash
# project volumeを保持したままRuntimeとIngesterを停止する。
docker compose stop llmwiki llmwiki-ingester
```

停止後も `llmwiki-project` volume 内の `sources/`、`wiki/`、`.llmwiki/` は保持される。

```bash
# LLMWikiだけを初期化する場合に、停止済みproject volumeを削除する。
docker volume rm "${STACK_NAME}_llmwiki-project"
```

volumeを削除すると生成済みsource、Wiki、同期manifestは復旧できない。CouchDBの原本は削除されないため、再起動後の同期とcompileで再生成できる。

## References

- [llm-wiki-compiler](https://github.com/atomicstrata/llm-wiki-compiler)
- [Viewer CLI](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/cli/view.mdx)
- [Environment Variables](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/configuration/environment-variables.mdx)
- [sources Input Contract](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/SOURCES_CONTRACT.md)
- [MCP Server](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/cli/serve.mdx)
- [Open Knowledge Format](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/guides/open-knowledge-format.mdx)
- [Apache CouchDB `_all_docs`](https://docs.couchdb.org/en/stable/api/database/bulk-api.html#db-all-docs)
