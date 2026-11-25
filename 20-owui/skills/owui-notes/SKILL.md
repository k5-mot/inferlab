---
name: owui-notes
description: >
  Search, read, create and update the user's Notes in Open WebUI (meeting notes, design notes). Use when the user refers to notes or past meeting records.
---

# Notes

```bash
# Search notes by text.
owui-api GET '/api/v1/notes/search?query=設計会議' | jq -r '.items[] | [.id, .title] | @tsv'
# Read one note (content in .data.content.md).
owui-api GET /api/v1/notes/<id> | jq -r '.title, .data.content.md'
# Create a note.
owui-api POST /api/v1/notes/create '{"title":"...","data":{"content":{"md":"..."}}}'
```

Updating or deleting someone else's shared note needs explicit user approval.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
