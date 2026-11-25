---
name: owui-search
description: >
  Search across the user's Open WebUI chats, channel messages and notes in one call. Use when the user asks
  "where did we discuss ..." or the source type is unknown. For document knowledge bases use owui-knowledge.
---

# Global search

```bash
# Search everything the user can see (kind: all, chat, message, note).
owui-api GET '/api/v1/search?q=認証基盤&kind=all' | jq -r '.items[] | [.kind, .id, .title] | @tsv'
# Only the user's own notes, next page.
owui-api GET '/api/v1/search?q=認証基盤&kind=note&sharing=mine&page=2' | jq '.has_more, [.items[].title]'
# Limit to a folder or channel (ids from .scopes of a previous response).
owui-api GET '/api/v1/search?q=認証基盤&scope=folder:<folder-id>' | jq -r '.items[] | [.kind, .title, .context] | @tsv'
```

- Results are keyword matches with a short `.content` excerpt. Read the full item with
  owui-chats, owui-channels or owui-notes before quoting it.
- This does not search knowledge base documents (no embeddings). Use owui-knowledge for those.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
