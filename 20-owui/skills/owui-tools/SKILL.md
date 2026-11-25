---
name: owui-tools
description: >
  Inspect and call tools registered in Open WebUI: OpenAPI tool servers (for example LibreTranslate), MCP servers
  via mcpo, and workspace tools. Use to discover which tools exist and to call an OpenAPI tool server directly.
---

# Tools

```bash
# Tools available to the user.
owui-api GET /api/v1/tools/ | jq -r '.[] | [.id, .name] | @tsv'
# Function specs (name, description, JSON schema of parameters) of every visible tool.
owui-api GET /api/v1/tools/ | jq '.[] | {id, specs: [.specs[]? | {name, description, parameters}]}'
```

## Calling an OpenAPI tool server directly

`owui-api tool <server-id> <METHOD> <path> [json]` calls a tool server through owui-broker.
`<server-id>` is the part after `server:`. Only servers listed for the user above are reachable.

```bash
# Translate with LibreTranslate.
owui-api tool libretranslate POST /translate '{"q":"認証基盤","source":"ja","target":"en"}' | jq -r .translatedText
```

- The JSON body is the function's `parameters`. HTTP paths of InferLab's tool servers:

  | Server id | Path |
  | --- | --- |
  | `libretranslate` | `POST /translate` (`translateText`) |
  | `open-webui` (mcpo, admin only) | `POST /<mcp-server>/<tool-name>`, e.g. `/time/get_current_time` |

  For other servers, read the server's OpenAPI document, e.g. `owui-api tool <id> GET /openapi.json`.
- Workspace tools (Python) and server-side tool calling run inside Open WebUI chat completions,
  which are blocked for agents (recursion risk). Use the direct REST skills for the data instead.
- Do not create, update or delete tools. Tool code runs on the Open WebUI server.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
