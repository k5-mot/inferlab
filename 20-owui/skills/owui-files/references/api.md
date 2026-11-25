# owui-files API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/files/`

List Files

- parameters: `page` (query, integer), `content` (query, boolean)

### `POST /api/v1/files/`

Upload File

- parameters: `process` (query, boolean), `process_in_background` (query, boolean)
- body (multipart/form-data): `file`*: string, `metadata`: object | string

### `DELETE /api/v1/files/all`

Delete All Files


### `GET /api/v1/files/count`

Count Files


### `GET /api/v1/files/search`

Search Files

- parameters: `filename` (query, string, required), `content` (query, boolean), `skip` (query, integer), `limit` (query, integer)

### `GET /api/v1/files/user/count`

Count User Files


### `GET /api/v1/files/user/search`

Search User Files

- parameters: `filename` (query, string), `content` (query, boolean), `skip` (query, integer), `limit` (query, integer)

### `GET /api/v1/files/{id}`

Get File By Id

- parameters: `id` (path, string, required)

### `DELETE /api/v1/files/{id}`

Delete File By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/files/{id}/content`

Get File Content By Id

- parameters: `id` (path, string, required), `attachment` (query, boolean)

### `GET /api/v1/files/{id}/content/html`

Get Html File Content By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/files/{id}/content/{file_name}`

Get File Content By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/files/{id}/data/content`

Get File Data Content By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/files/{id}/data/content/update`

Update File Data Content By Id

- parameters: `id` (path, string, required)
- body (application/json): `content`*: string

### `GET /api/v1/files/{id}/process/status`

Get File Process Status

- parameters: `id` (path, string, required), `stream` (query, boolean)

### `POST /api/v1/files/{id}/rename`

Rename File By Id

- parameters: `id` (path, string, required)
- body (application/json): `filename`*: string
