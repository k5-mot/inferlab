---
name: owui-memory
description: >
  Search and add the user's long-term memories stored in Open WebUI. Use for user preferences, policies or facts the user asked Open WebUI to remember.
---

# Memory

```bash
# Semantic search in the user's memories (404 = no memories yet).
owui-api POST /api/v1/memories/query '{"content":"開発方針","k":5}'
# List all memories.
owui-api GET /api/v1/memories/
# Add a memory (only when the user asks to remember something).
owui-api POST /api/v1/memories/add '{"content":"..."}'
```

Reset and delete need explicit user approval.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
