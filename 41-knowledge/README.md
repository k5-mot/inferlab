# 41-knowledge

`llm-wiki`をHTTP MCP serverとして公開し、Hermes-AgentとOpenClawから利用するprofile。

## 構成

- `llm-wiki`: Git backed Markdown wiki engine。初回起動時に`inferlab` spaceを作成する。
- `llm-wiki-data`: wiki repository本体を保存するvolume。
- `llm-wiki-state`: `llm-wiki`のglobal configとindex stateを保存するvolume。

## 方針

CouchDBからLLMwikiへ同期する独自workerは作らない。保守対象を増やさないため、取り込みはHermes-Agentの既存cron/agent機能からCouchDB APIと`llm-wiki` MCPを使って実行する。

## 起動手順

```bash
# Knowledge profileだけを起動する。
sudo docker compose --env-file .env --profile knowledge up -d
```

期待結果:

- `llm-wiki`が`http://${PUBLIC_HOST}:${LLM_WIKI_HTTP_HOST_PORT:-34100}/mcp`でHTTP MCPを公開する。
- Hermes-AgentとOpenClawのMCP設定に`llm_wiki` serverが追加される。
- Hermes-AgentとOpenClawから`/wikis/inferlab`配下のMarkdownを編集できる。

失敗条件:

- `llm-wiki`が`healthy`にならない。
- Hermes-AgentまたはOpenClawから`llm_wiki` MCP serverへ接続できない。
- `llm-wiki-data` volumeの権限不足でagentがMarkdownを更新できない。

## CouchDB取り込み

Hermes-Agentから次のようなcronを作る。

```bash
# Hermes-Agentの既存cron機能でCouchDB取り込みを定期実行する。
sudo docker compose --env-file .env --profile hermes-agent exec hermes-agent hermes cron create "every 1h" 'CouchDB(${COUCHDB_URL})から最近更新されたObsidian文書を確認し、llm_wiki MCPでinferlab wikiへ反映してください。既存ページは差分更新し、根拠となるCouchDB database名とdocument idをMarkdownに残してください。' --name "couchdb-to-llmwiki"
```

## References

- [llm-wiki](https://github.com/geronimo-iia/llm-wiki)
- [llm-wiki installation](https://github.com/geronimo-iia/llm-wiki/blob/main/docs/guides/installation.md)
- [llm-wiki IDE integration](https://github.com/geronimo-iia/llm-wiki/blob/main/docs/guides/ide-integration.md)
- [Hermes Agent MCP Config Reference](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference)
- [Hermes Agent Scheduled Tasks](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)
