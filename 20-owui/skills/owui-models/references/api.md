# owui-models API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/models`

Get Models

- parameters: `refresh` (query, boolean), `terminal_id` (query, string), `chat_id` (query, string), `cwd` (query, string)

### `GET /api/models/base`

Get Base Models


### `POST /api/models/unload`

Unload Model

- body (application/json): `model`*: string

### `GET /api/v1/models`

Get Models

- parameters: `refresh` (query, boolean), `terminal_id` (query, string), `chat_id` (query, string), `cwd` (query, string)

### `GET /api/v1/models/all`

Get All Model Records


### `GET /api/v1/models/base`

Get Base Models

- parameters: `tag` (query, string)

### `GET /api/v1/models/base/tags`

Get Base Model Tags


### `POST /api/v1/models/create`

Create New Model

- body (application/json): `access_grants`: array<object>, `base_model_id`: string, `commit_message`: string, `id`*: string, `is_active`: boolean, `meta`*: ModelMeta, `name`*: string, `params`*: ModelParams

### `DELETE /api/v1/models/delete/all`

Delete All Models


### `GET /api/v1/models/export`

Export Models

- parameters: `ids` (query, array<string>)

### `POST /api/v1/models/import`

Import Models

- body (application/json): `models`*: array<object>

### `GET /api/v1/models/list`

Get Models

- parameters: `query` (query, string), `view_option` (query, string), `tag` (query, string), `order_by` (query, string), `direction` (query, string), `page` (query, integer)

### `GET /api/v1/models/model`

Get Model By Id

- parameters: `id` (query, string, required)

### `POST /api/v1/models/model/access/update`

Update Model Access By Id

- body (application/json): `access_grants`*: array<object>, `id`*: string, `name`: string

### `POST /api/v1/models/model/delete`

Delete Model By Id

- body (application/json): `id`*: string

### `GET /api/v1/models/model/history`

Get Model History

- parameters: `id` (query, string, required), `page` (query, integer)

### `GET /api/v1/models/model/history/{history_id}`

Get Model History Entry

- parameters: `history_id` (path, string, required), `id` (query, string, required)

### `DELETE /api/v1/models/model/history/{history_id}`

Delete Model History Entry

- parameters: `history_id` (path, string, required), `id` (query, string, required)

### `GET /api/v1/models/model/profile/image`

Get Model Profile Image

- parameters: `id` (query, string, required)

### `POST /api/v1/models/model/toggle`

Toggle Model By Id

- parameters: `id` (query, string, required)

### `POST /api/v1/models/model/update`

Update Model By Id

- body (application/json): `access_grants`: array<object>, `base_model_id`: string, `commit_message`: string, `id`*: string, `is_active`: boolean, `meta`*: ModelMeta, `name`*: string, `params`*: ModelParams

### `POST /api/v1/models/model/update/version`

Set Model Version

- parameters: `id` (query, string, required)
- body (application/json): `version_id`*: string

### `POST /api/v1/models/sync`

Sync Models

- body (application/json): `models`: array<ModelModel>

### `GET /api/v1/models/tags`

Get Model Tags
