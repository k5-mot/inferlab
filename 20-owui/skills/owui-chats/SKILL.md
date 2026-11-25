---
name: owui-chats
description: >
  Search and read the user's past Open WebUI chat history. Use when the user refers to an earlier conversation.
---

# Chats

```bash
# Search chats by text.
owui-api GET '/api/v1/chats/search?text=基本設計' | jq -r '.[] | [.id, .title] | @tsv'
# Read a chat.
owui-api GET /api/v1/chats/<id> | jq '.chat.messages[] | {role, content}'
```

Do not delete, archive or share chats unless the user explicitly asks.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
