# llm-wiki v0.5.5のMCP URLとwiki pathの必要条件

## Summary

調査日: 2026-08-12

Hermes-Agent/OpenClawがllm-wiki v0.5.5を通常のMCPクライアントとして使うだけなら、`LLM_WIKI_MCP_URL`相当のHTTP MCP endpointだけで十分である。実行中の`llm-wiki`は`http://llm-wiki:8080/mcp`でMCP toolを公開しており、MCP schema上も`wiki_content_read`、`wiki_content_write`、`wiki_content_commit`、`wiki_ingest`、`wiki_search`などが利用できる。

`LLM_WIKI_SPACE_PATH`とHermes-Agent/OpenClawへの`/wikis` bind mountが必要になるのは、MCP toolではなくクライアント側のterminal/file toolからwiki repositoryを直接読み書きする場合である。具体的には、`wiki_resolve`や`wiki_content_new`が返すローカルpathへクライアントが直接書く運用、Hermes cron promptで`$LLM_WIKI_SPACE_PATH/...`へMarkdownを書く運用、またはsync-workerなど別プロセスがwiki volumeを直接更新する運用で必要になる。

## Local Findings

`41-knowledge/docker-compose.yml`では、llm-wiki serviceだけが`llm-wiki-data:/wikis`をmountし、`LLM_WIKI_SPACE_PATH`を`/wikis/${LLM_WIKI_SPACE_NAME:-inferlab}`としている。`41-knowledge/llm-wiki/entrypoint.sh`はこのpathでspaceを作成または登録し、HTTP `:8080`とfilesystem watcherを有効にしてserveする。

実行中binaryのversion確認結果は`llm-wiki 0.5.5`だった。top-level helpでは`content`、`search`、`list`、`ingest`、`serve`、`watch`などのcommandが確認できた。serveのhelpはHTTP transportとfilesystem watcherを有効化できる仕様だった。contentのhelpはread/write/new/commitを持ち、ingestのhelpはwiki tree内pathをvalidate/index/commit対象にするcommandだった。

実行中のMCP endpointへJSON-RPCで`initialize`と`tools/list`を実行した結果、serverは`llm-wiki` version `0.5.5`として応答し、`wiki_content_write`、`wiki_content_commit`、`wiki_ingest`、`wiki_search`、`wiki_list`、`wiki_resolve`などを公開していた。`wiki_content_write`は`uri`と`content`を必須引数に持つため、MCP URLだけでページ本文を書き込める。`wiki_ingest`は`path`を「wiki rootからの相対path」として受け取り、validate/commit/indexを行うtoolとして公開されていた。

`10-inference/hermes/config.yaml`では、`mcp.servers.llm_wiki.url`が`http://llm-wiki:8080/mcp`に固定されている。`10-inference/openclaw/custom-image/openclaw.template.json`でも`mcp.servers.llm_wiki.url`が同じURLに固定されている。一方、`10-inference/docker-compose.yml`の`LLM_WIKI_MCP_URL`環境変数は、現時点のHermes/OpenClaw MCP設定ファイルでは参照されていない。`LLM_WIKI_SPACE_PATH`はHermes cron promptで直接参照され、`$LLM_WIKI_SPACE_PATH/couchdb/...`へMarkdownを書く手順に使われている。

## Upstream Findings

llm-wiki v0.5.5公式READMEは、llm-wikiを「MCP-compatible agentから利用できるGit-backed Markdown wiki」と説明し、LLMは外部にあり、MCP経由でページを読み、書き、commitすると説明している。READMEのtool一覧でも、`wiki_content_write`はページ書き込み、`wiki_ingest`はvalidate/index/commit、`wiki_search`は検索を行うtoolとして説明されている。

公式IDE integration guideは、HTTP transportではserveにHTTP endpointを持たせ、IDE側は`http://localhost:8080/mcp`を指す、と説明している。またworkflow例では、agentが`wiki_content_new`、`wiki_content_write`、`wiki_ingest`を順に呼んでページ作成と取り込みを完了する流れを示している。

公式tool specificationでは、`wiki_content_write`はwiki treeへfileを書き込むがvalidate/index/commitはしない、`wiki_content_commit`と`wiki_ingest`だけがGitへ書く、と説明されている。`wiki_ingest` specificationは、`ingest.auto_commit`がtrueならvalidate、index更新、Git commitまで行うと説明している。

一方で、公式specificationとADRは直接ファイル更新パターンも明示している。`wiki_content_new`と`wiki_resolve`はローカルfilesystem pathを返し、Claude Codeのように直接filesystemへ書けるクライアントでは、MCPの本文round-tripを避けてnative file toolで書き、最後に`wiki_ingest`を呼ぶ設計になっている。この運用はクライアント側から同じfilesystem pathが見えていることを前提にするため、container分離されたHermes-Agent/OpenClawで実行するなら`/wikis` mountが必要になる。

## Answer

Hermes-Agent/OpenClawからllm-wikiを「MCP tool server」として利用する範囲では、`LLM_WIKI_MCP_URL`相当のURLだけで実現可能である。検索、一覧、読み取り、ページ本文の書き込み、commit、ingest、index rebuild/status、graph/stats/lintなどはMCP toolとして公開されているため、Hermes-Agent/OpenClaw containerに`/wikis`をmountする必要はない。

`LLM_WIKI_SPACE_PATH`と`/wikis` mountが必要になる条件は次の通り。

- Hermes-Agent/OpenClawのterminal/file toolがwiki Markdownを直接作成・編集する場合。
- `wiki_resolve`または`wiki_content_new`で返ったローカルpathへ、MCPを介さず直接書き込む場合。
- Hermes cron promptのように`$LLM_WIKI_SPACE_PATH/couchdb/...`へ直接Markdownを書く手順を維持する場合。
- sync-workerをHermes-Agent/OpenClaw側、または別sidecarとして実装し、MCPではなくshared volumeへ直接出力する場合。
- llm-wikiの`--watch`に外部ファイル更新を拾わせる設計にする場合。

したがって、sync-worker方式へ切り替える場合の設計は2択になる。

1. sync-workerがllm-wiki MCP URLへ`wiki_content_write`と`wiki_ingest`を呼ぶ方式  
   workerに`/wikis` mountは不要。URL、CouchDB接続情報、checkpoint用stateだけを持たせる。container境界が明確で、llm-wikiへの永続化はMCP APIに集約される。

2. sync-workerが`llm-wiki-data:/wikis`を共有して直接Markdownを書き、`wiki_ingest`だけをMCPまたはllm-wiki CLIで呼ぶ方式  
   大量ファイル更新時のMCP本文転送は減るが、workerに`/wikis` mountとpath設定が必要になる。権限、path整合性、watch/ingest順序の管理が増える。

保守コストを下げる観点では、CouchDB to LLMwiki sync-workerはMCP URL方式を第一候補にするのが妥当である。Hermes-Agent/OpenClaw側からは`/wikis` mountと`LLM_WIKI_SPACE_PATH`を外し、MCP URLだけを設定する構成に寄せられる。ただし、大量ドキュメントを高頻度で更新し、MCP request body sizeや処理時間が問題になる場合だけ、shared volume直接書き込み方式を検討する。

## References

- `41-knowledge/docker-compose.yml`
- `41-knowledge/llm-wiki/entrypoint.sh`
- `10-inference/docker-compose.yml`
- `10-inference/hermes/config.yaml`
- `10-inference/hermes/cron/prompts/couchdb-to-llmwiki.md`
- `10-inference/openclaw/custom-image/openclaw.template.json`
- llm-wiki v0.5.5 README: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/README.md
- llm-wiki v0.5.5 IDE integration guide: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/docs/guides/ide-integration.md
- llm-wiki v0.5.5 tool overview: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/docs/specifications/tools/overview.md
- llm-wiki v0.5.5 content operations specification: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/docs/specifications/tools/content-operations.md
- llm-wiki v0.5.5 ingest specification: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/docs/specifications/tools/ingest.md
- llm-wiki v0.5.5 MCP clients specification: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/docs/specifications/integrations/mcp-clients.md
- llm-wiki v0.5.5 Local Path in Content Tools ADR: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/docs/decisions/0.2.0/local-path-content.md
- llm-wiki v0.5.5 server source: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/src/server.rs
- llm-wiki v0.5.5 MCP tools source: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/src/mcp/tools.rs
- llm-wiki v0.5.5 MCP handlers source: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/src/mcp/handlers.rs
- llm-wiki v0.5.5 content source: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/src/ops/content.rs
- llm-wiki v0.5.5 ingest source: https://raw.githubusercontent.com/geronimo-iia/llm-wiki/v0.5.5/src/ops/ingest.rs
