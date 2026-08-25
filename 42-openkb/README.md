# LLM Wiki Platform

OpenKBをKnowledge Compilerとして利用し、社内sourceの取り込み、定期compile、Mintlify Viewerでの閲覧、Wiki.js LLM Wikiへの任意公開を管理するserviceである。

現時点の `config.yaml` は `40-obsidian` のCouchDB Connectorだけを有効化し、その他のConnectorとcompile/publishを無効化している。Composeは `OBSIDIAN_COUCHDB_USER` と `OBSIDIAN_COUCHDB_PASSWORD` をCouchDBとAPI containerの両方へ渡す。

## 開発環境

```bash
# project依存関係と開発toolを同期する。
uv sync --project 42-openkb

# unit testを実行する。
uv run --project 42-openkb pytest 42-openkb/tests

# lintを実行する。
uv run --project 42-openkb ruff check 42-openkb/src 42-openkb/tests

# formatを変更せず検査する。
uv run --project 42-openkb ruff format --check 42-openkb/src 42-openkb/tests

# static type checkを実行する。
uv run --project 42-openkb mypy --config-file 42-openkb/pyproject.toml 42-openkb/src

# Mintlify Viewerの依存関係を同期する。
pnpm --dir 42-openkb/viewer install --frozen-lockfile

# Viewerのbuild、unit test、type checkを実行する。
pnpm --dir 42-openkb/viewer test
pnpm --dir 42-openkb/viewer typecheck
```

期待結果:

- `uv sync`が `42-openkb/.venv` を作成する。
- PythonとViewerのtest、lint、format、type checkがすべて終了code 0で完了する。

失敗基準:

- `config.yaml` のschema違反またはcredential参照不足がある場合、serviceは起動してはならない。
- test、lint、format、type checkのいずれかが終了code 0以外なら変更を完了扱いにしてはならない。

## 設定反映

MVPでは設定を起動時にだけ読み込む。`config.yaml` またはcredential環境変数を変更した場合は、`llm-wiki-api` と `openkb-viewer` containerを再起動する。稼働中のreload endpointは提供しない。

API processがschedulerとjob実行を所有する。MVPではworker containerを分離しないため、同じscheduleを複数processが登録することはない。

## 起動

```bash
# OpenKB pipelineとMintlify Viewerをbuildして起動する。
docker compose --profile openkb up -d --build openkb llm-wiki-api openkb-viewer

# containerとhealth状態を確認する。
docker compose ps openkb llm-wiki-api openkb-viewer
```

期待結果:

- `openkb`、`llm-wiki-api`、`openkb-viewer`がhealthyになる。
- 管理APIのSwagger UIを `http://localhost:34200/docs` で表示できる。
- 同期dashboardを `http://localhost:34200/dashboard` で表示できる。
- Mintlify Viewerを `http://localhost:34201` で表示できる。
- Viewerの `Graph View` でGenerated Wikiの記事とWiki linkを表示できる。
- CouchDB ingestのscheduled jobが登録され、CouchDBは `openkb` profileで自動起動する。

失敗基準:

- `llm-wiki-api`が起動直後に終了した場合、container logに示されたconfig schemaまたはcredential環境変数を修正する。
- OpenKBがhealthyにならない場合、OpenKB image buildとvolume権限を確認する。
- Viewerがhealthyにならない場合、Mintlify CLIの起動logと `viewer` 設定を確認する。

## CouchDB ingest

CouchDB ConnectorはSelf-hosted LiveSyncの完全snapshotから、非削除のMarkdown親documentと順序付きleaf chunkを復元する。`.obsidian`などのhidden path、`ix:` prefix、Markdown以外のdocumentは取り込まない。

`title_strategy: hierarchy` により、Obsidianのfolder階層を空白区切りでtitleへ反映する。階層名の重複は保持するため、`AWS/AWS CLF/事前テスト.md` は `AWS AWS CLF 事前テスト` になる。

```bash
# CouchDB sourceのingestを手動実行する。
curl --fail --request POST http://localhost:34200/ingest/couchdb
```

期待結果:

- APIはingest jobの受付結果を返す。
- run完了後、Source StoreへCouchDB noteのCanonical Documentとraw Markdownが保存される。
- 次回compileで変更済みnoteがOpenKBへ投入される。

失敗基準:

- CouchDB認証、snapshot応答、親documentのchunk参照が不正な場合、runは失敗する。
- 公開対象Markdownが `max_documents` を超えた場合、部分snapshotとして保存せず失敗する。

## Viewerのデータ境界

`openkb-viewer` はOpenKB volumeの `internal-wiki/wiki` をread-only mountする。生成Markdownを `/data/mintlify/site` へ複製し、以下を表示用に生成する。

- directory階層を保ったMintlify navigation
- OpenKB wikilinkをViewer内URLへ変換した記事
- 記事をnode、解決済みWiki linkをedgeとするGraph data

source digestを `viewer.poll_seconds` 間隔で確認し、変更時だけworkspaceを置換してMintlify previewを再起動する。空のGenerated Wikiでも空状態pageを表示してhealthyを維持する。

Rollback:

```bash
# pipelineとViewerを停止し、Source StoreとOpenKB volumeは保持する。
docker compose stop openkb-viewer llm-wiki-api openkb
```

## References

- [OpenKB REST API](https://github.com/VectifyAI/OpenKB/blob/main/examples/rest-api/README.md)
- [Tabler](https://docs.tabler.io/)
- [Mintlify CLI preview](https://www.mintlify.com/docs/cli/preview)
- [Mintlify navigation](https://www.mintlify.com/docs/organize/navigation)
- [Mintlify images and embeds](https://www.mintlify.com/docs/create/image-embeds)
- [Mintlify custom scripts](https://www.mintlify.com/docs/customize/custom-scripts)
- [Cytoscape.js](https://js.cytoscape.org/)
- [Apache CouchDB Mango Queries](https://docs.couchdb.org/en/stable/api/database/find.html)
- [Apache CouchDB `_all_docs`](https://docs.couchdb.org/en/stable/api/database/bulk-api.html#db-all-docs)
- [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)
- [Wiki.js GraphQL API](https://docs.requarks.io/dev/api)
- [GitLab REST API](https://docs.gitlab.com/api/api_resources/)
- [Zulip REST API](https://zulip.com/api/rest)
- [Nextcloud WebDAV API](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html)
- [Kaneo API Reference](https://kaneo.app/docs/api-reference/introduction)
