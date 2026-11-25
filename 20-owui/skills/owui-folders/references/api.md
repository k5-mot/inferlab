# owui-folders API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/folders/`

Get Folders


### `POST /api/v1/folders/`

Create Folder

- body (application/json): `data`: object, `meta`: object, `name`*: string, `parent_id`: string

### `GET /api/v1/folders/shared`

Get Shared Folders


### `GET /api/v1/folders/{id}`

Get Folder By Id

- parameters: `id` (path, string, required)

### `DELETE /api/v1/folders/{id}`

Delete Folder By Id

- parameters: `id` (path, string, required), `delete_contents` (query, boolean)

### `POST /api/v1/folders/{id}/access/update`

Update Folder Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>, `share_mode`: string

### `GET /api/v1/folders/{id}/automations`

Get Folder Automations

- parameters: `id` (path, string, required)

### `PATCH /api/v1/folders/{id}/chats/{chat_id}/status`

Update Folder Chat Status

- parameters: `id` (path, string, required), `chat_id` (path, string, required)
- body (application/json): `status`: string

### `POST /api/v1/folders/{id}/read`

Mark Folder Chats Read By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/folders/{id}/shared/chats`

Get Shared Folder Chats

- parameters: `id` (path, string, required), `page` (query, integer), `sort_by` (query, string), `sort_dir` (query, string), `workspace` (query, boolean), `search` (query, string), `tag_ids` (query, array<string>), `user_ids` (query, array<string>), `status` (query, array<string>), `activity` (query, string), `updated_at_gte` (query, integer)

### `GET /api/v1/folders/{id}/tags`

Get Folder Tags

- parameters: `id` (path, string, required)

### `POST /api/v1/folders/{id}/update`

Update Folder Name By Id

- parameters: `id` (path, string, required)
- body (application/json): `data`: object, `meta`: object, `name`: string

### `POST /api/v1/folders/{id}/update/expanded`

Update Folder Is Expanded By Id

- parameters: `id` (path, string, required)
- body (application/json): `is_expanded`*: boolean

### `POST /api/v1/folders/{id}/update/parent`

Update Folder Parent Id By Id

- parameters: `id` (path, string, required)
- body (application/json): `parent_id`: string

### `GET /api/v1/folders/{id}/users`

Get Folder Users

- parameters: `id` (path, string, required)
