Hermes CLI is available as `hermes` in terminal sessions because /opt/hermes/bin is added by /opt/data/terminal-env.sh.
§
This Hermes runtime runs tool commands as user hermes (uid 1000) with HERMES_HOME=/opt/data and cwd=/opt/data.
§
Configured MCP servers in this environment include searxng via `npx mcp-searxng@1.14.0` and docling via `uvx --from docling-mcp==3.0.0 docling-mcp-server --transport stdio`.
