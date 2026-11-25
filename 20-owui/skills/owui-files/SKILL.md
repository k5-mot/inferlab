---
name: owui-files
description: >
  Read, download, upload and inspect files stored in Open WebUI (including Docling-extracted text). Use to fetch the original of a knowledge document or to hand a generated file back to Open WebUI.
---

# Files

```bash
# Files owned by the current user.
owui-api GET '/api/v1/files/?content=false' | jq -r '.items[] | [.id, .filename] | @tsv'
# Extracted text of a file (Docling output for PDFs).
owui-api GET /api/v1/files/<id>/data/content | jq -r .content
# Download the original binary.
owui-api download <id> ./original.pdf
# Upload a local file (processed for RAG by Open WebUI).
owui-api upload ./report.docx | jq -r .id
# Processing status after upload.
owui-api GET /api/v1/files/<id>/process/status
```

- Knowledge search results contain `metadata.file_id`; use it here.
- Deleting files needs explicit user approval (`OWUI_CONFIRM=yes`).

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
