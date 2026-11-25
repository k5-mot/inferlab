---
name: owui-folders
description: >
  List and manage the user's chat folders in Open WebUI.
---

# Folders

```bash
# Folder list.
owui-api GET /api/v1/folders/
```

Creating, moving or deleting folders requires the user's request; deletion needs approval.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
