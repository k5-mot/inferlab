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
# Create a note: write the markdown to a file first, check it is not empty, then build the JSON with jq.
test -s summary.md && jq -n --arg title "設計会議 要約" --rawfile md summary.md \
  '{title: $title, data: {content: {md: $md}}}' | owui-api POST /api/v1/notes/create @- | jq -r .id
# Confirm it was saved (the id from the previous command; there is no /notes/get endpoint).
owui-api GET /api/v1/notes/<id> | jq -r '.title, .data.content.md'
```

Create a note only once. If creation printed an id, do not create it again; read it back instead.

Updating or deleting someone else's shared note needs explicit user approval.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
