---
name: owui-models
description: >
  List models and model presets available to the user in Open WebUI.
---

# Models

```bash
# Models the user can use.
owui-api GET /api/models | jq -r '.data[] | [.id, .name] | @tsv'
```

Inference itself is not available through this skill (chat completions are blocked).

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
