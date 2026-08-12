# 41-knowledge

`llm-wiki`をHTTP MCP serverとして公開し、Hermes-AgentとOpenClawから利用するprofile。

## 構成

- `llm-wiki`: Git backed Markdown wiki engine。初回起動時に`inferlab` spaceを作成する。
- `couchdb-llmwiki-sync`: CouchDB `_changes`を読み、llm-wiki MCP経由でMarkdown pageへ同期するworker。
- `llm-wiki-data`: wiki repository本体を保存するvolume。
- `llm-wiki-state`: `llm-wiki`のglobal configとindex stateを保存するvolume。
- `couchdb-llmwiki-sync-state`: CouchDB checkpointとworker healthを保存するvolume。

## 方針

CouchDBからLLMwikiへの同期は、LLM agentのpromptではなくdeterministicなsync-workerへ閉じ込める。workerの外部interfaceはCouchDB接続情報、`LLM_WIKI_MCP_URL`、checkpoint用stateに限定する。

Hermes-AgentとOpenClawはLLMwikiのMCP clientであり、wiki repositoryのfilesystem pathを知る必要はない。`wiki_content_write`と`wiki_ingest`がMCP toolとして公開されるため、通常の読み書き、validate、index、Git commitはMCP URLだけで実行できる。

## 起動手順

```bash
# llm-wikiとCouchDB同期workerを起動する。
sudo docker compose --env-file .env --profile knowledge up -d
```

期待結果:

- `llm-wiki`が`http://${PUBLIC_HOST}:${LLM_WIKI_HTTP_HOST_PORT:-34100}/mcp`でHTTP MCPを公開する。
- Hermes-AgentとOpenClawのMCP設定に`llm_wiki` serverが追加される。
- `couchdb-llmwiki-sync`が`http://llm-wiki:8080/mcp`へ接続し、CouchDBの変更を`inferlab` wikiへ同期する。

失敗条件:

- `llm-wiki`が`healthy`にならない。
- Hermes-AgentまたはOpenClawから`llm_wiki` MCP serverへ接続できない。
- `couchdb-llmwiki-sync`の`/state/health.json`が`"status": "ok"`にならない。
- CouchDBが起動していない、または`COUCHDB_USER`/`COUCHDB_PASSWORD`が一致せず同期workerが認証できない。

## CouchDB取り込み

CouchDB同期workerは、次の不変条件を守る。

- CouchDB URLはPython標準ライブラリで構築し、shellの`&`展開に依存しない。
- `jq`やHermes `execute_code`へ依存しない。
- `password`、`secret`、`token`、`key`を含むfield名は`[REDACTED]`へ置換する。
- attachment本体はLLMwikiへ取り込まない。
- `wiki_content_write`でpageを書き込み、`wiki_ingest`でvalidate、index、Git commitを実行する。
- `wiki_ingest`が成功したdatabaseだけcheckpointを進める。

`COUCHDB_LLMWIKI_SYNC_MAX_DOCS_PER_DATABASE`で1回あたりのdatabase別処理件数を制限できる。既定値は`50`。

## References

- [llm-wiki](https://github.com/geronimo-iia/llm-wiki)
- [llm-wiki installation](https://github.com/geronimo-iia/llm-wiki/blob/main/docs/guides/installation.md)
- [llm-wiki IDE integration](https://github.com/geronimo-iia/llm-wiki/blob/main/docs/guides/ide-integration.md)
- [Hermes Agent MCP Config Reference](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference)
- [llm-wiki MCP URL and space path research](../docs/research/llm-wiki-mcp-url-and-space-path.md)
