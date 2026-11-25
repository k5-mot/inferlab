---
name: owui-calendar
description: >
  Read and manage the user's Open WebUI calendars and events. Use for schedule-related requests.
---

# Calendar

```bash
# Calendars of the user.
owui-api GET /api/v1/calendars/
```

See `references/api.md` for event endpoints and fields. Creating or changing events needs the
user's request; deleting needs explicit approval.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
