---
name: owui-knowledge
description: >
  Search internal knowledge bases, company documents, specifications and other indexed content using Open WebUI's existing RAG pipeline (hybrid search + reranking). Use for any question or document that should be based on internal information.
---

# Knowledge Retrieval

## Workflow

1. List knowledge bases the user can read:
   ```bash
   owui-api GET /api/v1/knowledge/ | jq -r '.items[] | [.id, .name, .description] | @tsv'
   ```
2. Choose only the knowledge bases whose name or description matches the request (usually one).
   Never pass every id: hybrid search scans each whole collection and large ones take minutes.
   Search with a short query and `k` of 5 or less. Run several focused queries rather than one broad query:
   ```bash
   owui-api POST /api/v1/retrieval/query/collection \
     '{"collection_names":["<kb-id>"],"query":"アクセストークンの有効期限","k":5}' \
     | jq -r '[.documents[0], .metadatas[0]] | transpose[] | "[\(.[1].source)]\n\(.[0])\n"'
   ```
3. Use only what the results say. If nothing relevant is returned, say so; do not invent facts.
4. Need the whole original? Download it with `owui-api download <metadata.file_id> <path>` (owui-files).
5. Cite each fact with the source name (`metadata.source`) and page (`metadata.page`) when present.

## Policy

- Open WebUI applies the configured embedding, hybrid search and reranking. Do not access Qdrant
  or build another index.
- A 403 means the user has no access to that knowledge base. Do not try other routes.
- Searching file names only: `GET /api/v1/knowledge/search/files?query=...`.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
