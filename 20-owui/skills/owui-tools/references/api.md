# owui-tools API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/tools/`

Get Tools

- parameters: `query` (query, string)

### `POST /api/v1/tools/create`

Create New Tools

- body (application/json): `access_grants`: array<object>, `commit_message`: string, `content`*: string, `id`*: string, `meta`*: ToolMeta, `name`*: string

### `GET /api/v1/tools/export`

Export Tools


### `GET /api/v1/tools/id/{id}`

Get Tools By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/tools/id/{id}/access/update`

Update Tool Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `DELETE /api/v1/tools/id/{id}/delete`

Delete Tools By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/tools/id/{id}/history`

Get Tool History

- parameters: `id` (path, string, required), `page` (query, integer)

### `GET /api/v1/tools/id/{id}/history/diff`

Get Tool History Diff

- parameters: `id` (path, string, required), `from_id` (query, string, required), `to_id` (query, string, required)

### `GET /api/v1/tools/id/{id}/history/{history_id}`

Get Tool History Entry

- parameters: `id` (path, string, required), `history_id` (path, string, required)

### `DELETE /api/v1/tools/id/{id}/history/{history_id}`

Delete Tool History Entry

- parameters: `id` (path, string, required), `history_id` (path, string, required)

### `POST /api/v1/tools/id/{id}/mcp/app/rpc`

Mcp App Rpc

- parameters: `id` (path, string, required)
- body (application/json): `binding`*: string, `method`*: string, `params`*: object, `tool_name`*: string

### `GET /api/v1/tools/id/{id}/specs`

Get Tool Specs

- parameters: `id` (path, string, required)

### `POST /api/v1/tools/id/{id}/toggle`

Toggle Tool By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/tools/id/{id}/update`

Update Tools By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`: array<object>, `commit_message`: string, `content`*: string, `id`*: string, `meta`*: ToolMeta, `name`*: string

### `POST /api/v1/tools/id/{id}/update/version`

Set Tool Production

- parameters: `id` (path, string, required)
- body (application/json): `version_id`*: string

### `GET /api/v1/tools/id/{id}/valves`

Get Tools Valves By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/tools/id/{id}/valves/spec`

Get Tools Valves Spec By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/tools/id/{id}/valves/update`

Update Tools Valves By Id

- parameters: `id` (path, string, required)
- body (application/json): object

### `GET /api/v1/tools/id/{id}/valves/user`

Get Tools User Valves By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/tools/id/{id}/valves/user/spec`

Get Tools User Valves Spec By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/tools/id/{id}/valves/user/update`

Update Tools User Valves By Id

- parameters: `id` (path, string, required)
- body (application/json): object

### `GET /api/v1/tools/list`

Get Tool List


### `POST /api/v1/tools/load/url`

Load Tool From Url

- body (application/json): `url`*: string
