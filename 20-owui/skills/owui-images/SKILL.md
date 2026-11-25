---
name: owui-images
description: >
  Generate images with Open WebUI's configured image generation backend, when the user asks for an image.
---

# Images

```bash
# Image generation (fails if no backend is configured).
owui-api POST /api/v1/images/generations '{"prompt":"..."}'
```

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
