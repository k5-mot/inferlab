# 41-knowledge

`llm-wiki`をHTTP MCP serverとして公開し、Hermes-AgentとOpenClawから利用するprofile。

## 構成

- `llm-wiki`: Git backed Markdown wiki engine。初回起動時に`inferlab` spaceを作成する。
- `llmwiki-sync-worker`: `config.yaml`で定義したsourceを読み、llm-wiki MCP経由でMarkdown pageへ同期するworker。
- `llmwiki-sync-worker WebUI`: source状態確認と手動同期triggerを提供するlocal-onlyの管理UI。
- `llm-wiki-data`: wiki repository本体を保存するvolume。
- `llm-wiki-state`: `llm-wiki`のglobal configとindex stateを保存するvolume。
- `llmwiki-sync-worker-state`: source別checkpointとworker healthを保存するvolume。

## 方針

外部サービスからLLMwikiへの同期は、LLM agentのpromptではなくdeterministicなsync-workerへ閉じ込める。workerの外部interfaceは`41-knowledge/llmwiki-sync-worker/config.yaml`、source別接続情報、`LLM_WIKI_MCP_URL`、checkpoint用stateに限定する。

workerはsource adapterを差し替え点にする。CouchDB、Nextcloud、BookStack、Zulip、Kaneo、GitLabの取得方法はadapter内に閉じ込め、同期loopは「設定を読む」「pageを書く」「ingestする」「checkpointを進める」だけを扱う。

Hermes-AgentとOpenClawはLLMwikiのMCP clientであり、wiki repositoryのfilesystem pathを知る必要はない。`wiki_content_write`と`wiki_ingest`がMCP toolとして公開されるため、通常の読み書き、validate、index、Git commitはMCP URLだけで実行できる。

## 起動手順

```bash
# llm-wikiとLLMwiki sync-workerを起動する。
sudo docker compose --env-file .env --profile knowledge up -d
```

期待結果:

- `llm-wiki`が`http://${PUBLIC_HOST}:${LLM_WIKI_HTTP_HOST_PORT:-34100}/mcp`でHTTP MCPを公開する。
- Hermes-AgentとOpenClawのMCP設定に`llm_wiki` serverが追加される。
- `llmwiki-sync-worker`が`http://llm-wiki:8080/mcp`へ接続し、enabled sourceの内容を`inferlab` wikiへ同期する。
- sync-worker WebUIが`http://127.0.0.1:${LLMWIKI_SYNC_WEB_HOST_PORT:-34101}`で表示できる。

失敗条件:

- `llm-wiki`が`healthy`にならない。
- Hermes-AgentまたはOpenClawから`llm_wiki` MCP serverへ接続できない。
- `llmwiki-sync-worker`の`/state/health.json`が`"status": "ok"`にならない。
- enabled sourceが起動していない、または認証情報が一致せず同期workerが認証できない。
- WebUIから`Status Check`または`Manual Trigger`を実行しても状態が更新されない。

## Source設定

`41-knowledge/llmwiki-sync-worker/config.yaml`で読み込み間隔、HTTP timeout、checkpoint path、LLMwiki MCP URL、同期sourceを定義する。`.env`では各sourceの有効化flag、最大件数、認証情報を上書きする。

既定ではCouchDBだけを有効化する。Nextcloud、BookStack、Zulip、Kaneo、GitLabはAPI tokenや専用userを発行してから、対応する`LLMWIKI_SYNC_*_ENABLED=true`を設定する。

同期workerは、次の不変条件を守る。

- HTTP URLはPython標準ライブラリで構築し、shellの`&`展開に依存しない。
- `jq`やHermes `execute_code`へ依存しない。
- `password`、`secret`、`token`、`key`、`authorization`、`cookie`、`session`を含むfield名は`[REDACTED]`へ置換する。
- attachment本体やfile本文はLLMwikiへ取り込まず、metadataだけを同期する。
- `wiki_content_write`でpageを書き込み、`wiki_ingest`でvalidate、index、Git commitを実行する。
- `wiki_ingest`が成功したsourceだけcheckpointを進める。

source別の初期対応範囲:

- CouchDB: `_all_dbs`と`_changes`からdocument差分を同期する。
- Nextcloud: WebDAV `PROPFIND`でfile/directory metadataを同期する。
- BookStack: REST APIのbooks/pages一覧を同期する。
- Zulip: streams/messages endpointのJSONを同期する。
- Kaneo: projects endpointのJSONを同期する。
- GitLab: REST APIのprojects一覧を同期する。

大量の本文抽出やbinary file取り込みは初期対応に含めない。必要になったsourceだけ、adapter内で取得範囲を広げる。

## WebUI

sync-workerは標準ライブラリのHTTP serverで軽量なWebUIを公開する。WebUIでは、最後の同期結果、最後のsource status check、source一覧を確認できる。`Manual Trigger`は同期をbackground threadで開始し、既に同期中なら`busy`を返す。

WebUIは認証を持たないため、既定では`LLMWIKI_SYNC_WEB_HOST_BIND=127.0.0.1`でlocal hostにだけ公開する。LANやpublic networkへ公開する場合は、reverse proxy側で認証とアクセス制限を追加する。

## References

- [llm-wiki](https://github.com/geronimo-iia/llm-wiki)
- [llm-wiki installation](https://github.com/geronimo-iia/llm-wiki/blob/main/docs/guides/installation.md)
- [llm-wiki IDE integration](https://github.com/geronimo-iia/llm-wiki/blob/main/docs/guides/ide-integration.md)
- [Hermes Agent MCP Config Reference](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference)
- [Nextcloud WebDAV basic APIs](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html)
- [BookStack API](https://www.bookstackapp.com/docs/admin/hacking-bookstack/)
- [Zulip get streams API](https://zulip.com/api/get-streams)
- [Zulip get messages API](https://zulip.com/api/get-messages)
- [Kaneo API reference](https://kaneo.app/docs/api-reference/introduction)
- [GitLab REST API](https://docs.gitlab.com/api/rest/)
- [llm-wiki MCP URL and space path research](../docs/research/llm-wiki-mcp-url-and-space-path.md)
