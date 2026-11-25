# owui-memory API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/memories/`

Get Memories


### `POST /api/v1/memories/add`

Add Memory

- body (application/json): `content`*: string, `path`: string, `type`: string

### `DELETE /api/v1/memories/delete/user`

Delete Memory By User Id


### `POST /api/v1/memories/path`

Read Memory Path

- body (application/json): `include_children`: boolean, `limit`: integer, `path`*: string, `type`: string

### `POST /api/v1/memories/paths`

List Memory Paths

- body (application/json): `limit`: integer, `query`: string, `type`: string

### `POST /api/v1/memories/query`

Query Memory

- body (application/json): `content`*: string, `k`: integer

### `POST /api/v1/memories/reindex`

Reindex Memories From Vector Db


### `POST /api/v1/memories/reset`

Reset Memory From Vector Db


### `POST /api/v1/memories/search`

Search Memories

- body (application/json): `limit`: integer, `memory_id`: string, `path`: string, `query`: string, `type`: string

### `POST /api/v1/memories/update`

Update Memories

- body (application/json): `operations`*: array<MemoryOperationModel>, `source`: string

### `DELETE /api/v1/memories/{memory_id}`

Delete Memory By Id

- parameters: `memory_id` (path, string, required)

### `POST /api/v1/memories/{memory_id}/update`

Update Memory By Id

- parameters: `memory_id` (path, string, required)
- body (application/json): `content`: string, `path`: string, `type`: string
