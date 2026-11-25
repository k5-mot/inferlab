# owui-knowledge API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/knowledge/`

Get Knowledge Bases

- parameters: `page` (query, integer)

### `POST /api/v1/knowledge/create`

Create New Knowledge

- body (application/json): `access_grants`: array<object>, `description`*: string, `meta`: KnowledgeMeta, `name`*: string

### `GET /api/v1/knowledge/external/connections`

Get External Knowledge Connections


### `POST /api/v1/knowledge/external/connections`

Create External Knowledge Connection

- body (application/json): `auth_config`: object, `capabilities`: object, `config`: object, `enabled`: boolean, `endpoint`*: string, `name`*: string, `provider`*: string

### `GET /api/v1/knowledge/external/connections/{id}`

Get External Knowledge Connection

- parameters: `id` (path, string, required)

### `PATCH /api/v1/knowledge/external/connections/{id}`

Update External Knowledge Connection

- parameters: `id` (path, string, required)
- body (application/json): `auth_config`: object, `capabilities`: object, `config`: object, `enabled`: boolean, `endpoint`*: string, `name`*: string, `provider`*: string

### `DELETE /api/v1/knowledge/external/connections/{id}`

Delete External Knowledge Connection

- parameters: `id` (path, string, required)

### `POST /api/v1/knowledge/external/connections/{id}/retrieve-test`

Test External Knowledge Retrieval

- parameters: `id` (path, string, required)
- body (application/json): `count`: integer, `query`*: string, `source`: ExternalKnowledgeSourceForm

### `POST /api/v1/knowledge/external/connections/{id}/test`

Test External Knowledge Connection

- parameters: `id` (path, string, required)

### `POST /api/v1/knowledge/external/knowledge/create`

Create External Knowledge

- body (application/json): `access_grants`: array<object>, `connection_id`*: string, `description`: string, `name`*: string, `source`*: ExternalKnowledgeSourceForm

### `POST /api/v1/knowledge/external/source/create`

Create External Knowledge Source

- body (application/json): `access_grants`: array<object>, `connection`*: ExternalKnowledgeConnectionForm, `description`: string, `name`*: string, `source`*: ExternalKnowledgeSourceForm, `test_count`: integer, `test_query`*: string

### `POST /api/v1/knowledge/external/source/stores`

List External Knowledge Stores

- body (application/json): `connection`*: ExternalKnowledgeConnectionForm, `connection_id`: string

### `POST /api/v1/knowledge/external/source/test`

Test External Knowledge Source

- body (application/json): `connection`*: ExternalKnowledgeConnectionForm, `connection_id`: string, `count`: integer, `query`*: string, `source`*: ExternalKnowledgeSourceForm

### `PATCH /api/v1/knowledge/external/source/{id}`

Update External Knowledge Source

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`: array<object>, `connection`*: ExternalKnowledgeConnectionForm, `description`: string, `name`*: string, `source`*: ExternalKnowledgeSourceForm, `test_count`: integer, `test_query`*: string

### `POST /api/v1/knowledge/metadata/reindex`

Reindex Knowledge Base Metadata Embeddings


### `POST /api/v1/knowledge/reindex`

Reindex Knowledge Files


### `GET /api/v1/knowledge/search`

Search Knowledge Bases

- parameters: `query` (query, string), `view_option` (query, string), `source` (query, string), `page` (query, integer), `order_by` (query, string), `direction` (query, string)

### `GET /api/v1/knowledge/search/files`

Search Knowledge Files

- parameters: `query` (query, string), `include_content` (query, boolean), `page` (query, integer)

### `GET /api/v1/knowledge/{id}`

Get Knowledge By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/knowledge/{id}/access/update`

Update Knowledge Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `DELETE /api/v1/knowledge/{id}/delete`

Delete Knowledge By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/knowledge/{id}/dirs/create`

Create Knowledge Directory

- parameters: `id` (path, string, required)
- body (application/json): `name`*: string, `parent_id`: string

### `DELETE /api/v1/knowledge/{id}/dirs/{dir_id}/delete`

Delete Knowledge Directory

- parameters: `id` (path, string, required), `dir_id` (path, string, required), `move_files` (query, boolean)

### `POST /api/v1/knowledge/{id}/dirs/{dir_id}/update`

Update Knowledge Directory

- parameters: `id` (path, string, required), `dir_id` (path, string, required)
- body (application/json): `name`: string, `parent_id`: string

### `GET /api/v1/knowledge/{id}/export`

Export Knowledge By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/knowledge/{id}/file/add`

Add File To Knowledge By Id

- parameters: `id` (path, string, required)
- body (application/json): `directory_id`: string, `file_id`*: string

### `POST /api/v1/knowledge/{id}/file/move`

Move File In Knowledge

- parameters: `id` (path, string, required)
- body (application/json): `directory_id`: string, `file_id`*: string

### `POST /api/v1/knowledge/{id}/file/remove`

Remove File From Knowledge By Id

- parameters: `id` (path, string, required), `delete_file` (query, boolean)
- body (application/json): `directory_id`: string, `file_id`*: string

### `POST /api/v1/knowledge/{id}/file/update`

Update File From Knowledge By Id

- parameters: `id` (path, string, required)
- body (application/json): `directory_id`: string, `file_id`*: string

### `GET /api/v1/knowledge/{id}/files`

Get Knowledge Files By Id

- parameters: `id` (path, string, required), `query` (query, string), `include_content` (query, boolean), `view_option` (query, string), `order_by` (query, string), `direction` (query, string), `directory_id` (query, string), `page` (query, integer), `limit` (query, integer)

### `POST /api/v1/knowledge/{id}/files/batch/add`

Add Files To Knowledge Batch

- parameters: `id` (path, string, required)
- body (application/json): array<KnowledgeFileIdForm>

### `GET /api/v1/knowledge/{id}/files/pending`

Get Pending Knowledge Files

- parameters: `id` (path, string, required), `stream` (query, boolean)

### `POST /api/v1/knowledge/{id}/files/validate`

Validate Knowledge Upload

- parameters: `id` (path, string, required)
- body (application/json): `count`*: integer, `file_size`: integer, `removed_file_ids`: array<string>

### `POST /api/v1/knowledge/{id}/reset`

Reset Knowledge By Id

- parameters: `id` (path, string, required), `include_directories` (query, boolean)

### `POST /api/v1/knowledge/{id}/sync/cleanup`

Sync Knowledge Cleanup

- parameters: `id` (path, string, required)
- body (application/json): `dir_ids`: array<string>, `file_ids`*: array<string>

### `POST /api/v1/knowledge/{id}/sync/diff`

Sync Knowledge Diff

- parameters: `id` (path, string, required)
- body (application/json): `manifest`*: array<FileManifestEntry>

### `POST /api/v1/knowledge/{id}/update`

Update Knowledge By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`: array<object>, `description`*: string, `meta`: KnowledgeMeta, `name`*: string

### `POST /api/v1/retrieval/query/collection`

Query Collection Handler

- body (application/json): `collection_names`*: array<string>, `enable_enriched_texts`: boolean, `hybrid`: boolean, `hybrid_bm25_weight`: number, `k`: integer, `k_reranker`: integer, `query`*: string, `r`: number

### `POST /api/v1/retrieval/query/doc`

Query Doc Handler

- body (application/json): `collection_name`*: string, `hybrid`: boolean, `hybrid_bm25_weight`: number, `k`: integer, `k_reranker`: integer, `query`*: string, `r`: number
