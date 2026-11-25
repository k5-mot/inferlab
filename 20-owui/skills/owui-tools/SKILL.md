---
name: owui-tools
description: >
  Inspect tools registered in Open WebUI: workspace tools, MCP servers via mcpo and OpenAPI tool servers. Use to discover which tools exist and their parameter specs.
---

# Tools

```bash
# Tools available to the user.
owui-api GET /api/v1/tools/ | jq -r '.[] | [.id, .name] | @tsv'
# Function specs of a tool.
owui-api GET /api/v1/tools/id/<id>/specs
```

- Server-side tool calling goes through Open WebUI chat completions, which are blocked for
  agents (recursion risk). Use the direct REST skill for the data instead when possible.
- Do not create, update or delete tools. Tool code runs on the Open WebUI server.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
