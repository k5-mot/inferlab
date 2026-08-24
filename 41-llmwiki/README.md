# LLM Wiki

`llm-wiki-compiler` 1.1.0 を Knowledge Compiler と read-only viewer に使用する。独自 runner は `config.yaml` の定期実行、source adapter、job 直列化、compile 後の viewer 再起動、Compose 向け HTTP proxy を担当する。

OpenKB と Wiki.js publish は使用しない。source-system 固有処理は共通のsource adapter interfaceの背後へ置く。runnerとschedulerはsource種別を判定せず、registryを通じて同期する。新しいデータソースは設定schema、正規化済み設定、adapterを追加し、upstreamの[`sources/` Input Contract](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/SOURCES_CONTRACT.md)に従って`ingestText`またはCLIへ委譲する。

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

CouchDBのcredentialは値ではなく参照環境変数名を設定する。

```yaml
sources:
  - id: obsidian-couchdb
    adapter: couchdb
    url: http://couchdb:5984
    database: obsidian
    username_env: COUCHDB_USERNAME
    password_env: COUCHDB_PASSWORD
    exclude_path_prefixes:
      - "ix:"
    max_documents: 1000
    ingest:
      enabled: true
      schedule: "0 */6 * * *"
```

## 開発

```bash
# runner依存関係を固定lockfileから導入する。
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
# llmwiki imageをbuildしてviewerを起動する。
docker compose --profile llmwiki up -d --build llmwiki

# containerとhealth状態を確認する。
docker compose ps llmwiki

# upstreamが認識しているproject状態を確認する。
docker compose exec -w /data/llmwiki llmwiki llmwiki status
```

期待結果:

- `llmwiki` container が healthy になる。
- `http://localhost:34100` で upstream viewer を表示できる。
- CouchDB同期とingest後compileのscheduled jobが登録される。

失敗基準:

- config schema、cron、timezone、必要 credential が不正な場合、runner は起動に失敗する。
- viewer または proxy が起動できない場合、container は healthy にならない。

## 手動確認

```bash
# CouchDBの現在snapshotをsourceへ同期し、on_ingest設定に従ってcompileする。
docker compose exec llmwiki node /app/dist/main.js ingest obsidian-couchdb

# config.yamlのprovider設定でone-shot compileを実行する。
docker compose exec -w /data/llmwiki llmwiki node /app/dist/main.js compile

# compile後にrunnerを再起動してviewer snapshotを更新する。
docker compose restart llmwiki
```

期待結果:

- CouchDB同期logに対象document数と`created`、`updated`、`unchanged`、`removed`が記録される。
- `sources/`へMarkdown sourceが生成され、compile後に`wiki/`が更新される。
- runner再起動後に`http://localhost:34100`で生成Wikiを表示できる。

失敗基準:

- CouchDBの認証、HTTP応答、LiveSync chunk参照のいずれかが不正な場合、snapshotを成功扱いにしてはならない。
- 対象Markdown数が`max_documents`を超えた場合、同期を中止する。

手動 `llmwiki compile` は runner 外で実行されるため、viewer 自動再起動の対象にならない。定常運用では `config.yaml` のscheduleまたは`compile.on_ingest`を使用する。

## Rollback

```bash
# project volumeを保持したままrunnerを停止する。
docker compose stop llmwiki
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
- [Apache CouchDB `_all_docs`](https://docs.couchdb.org/en/stable/api/database/bulk-api.html#db-all-docs)
