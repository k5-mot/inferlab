---
name: owui-channels
description: >
  Read Open WebUI Channels and their messages, and post messages when the user asks. Use for team channel information.
---

# Channels

```bash
# Channels the user can access.
owui-api GET /api/v1/channels/ | jq -r '.[] | [.id, .name] | @tsv'
# Recent messages.
owui-api GET '/api/v1/channels/<id>/messages?skip=0&limit=50'
```

Posting is sending a message to other people: show the text to the user and get explicit
approval before `POST /api/v1/channels/<id>/messages/post`.
Real-time events use WebSocket and are not available here.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
