# owui-notes API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/notes/`

Get Notes

- parameters: `page` (query, integer)

### `POST /api/v1/notes/create`

Create New Note

- body (application/json): `access_grants`: array<object>, `data`: object, `meta`: object, `title`*: string

### `GET /api/v1/notes/pinned`

Get Pinned Notes


### `GET /api/v1/notes/search`

Search Notes

- parameters: `query` (query, string), `view_option` (query, string), `permission` (query, string), `order_by` (query, string), `direction` (query, string), `page` (query, integer)

### `GET /api/v1/notes/{id}`

Get Note By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/notes/{id}/access/update`

Update Note Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `GET /api/v1/notes/{id}/chat`

Get Note Chat By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/notes/{id}/chat`

Create Note Chat By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/notes/{id}/chats`

Get Note Chats By Id

- parameters: `id` (path, string, required)

### `DELETE /api/v1/notes/{id}/delete`

Delete Note By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/notes/{id}/pages/update`

Update Note Pages

- parameters: `id` (path, string, required)
- body (application/json): `action`*: string, `before_id`: string, `new_id`: string, `order`: array<string>, `page_id`: string, `parent_id`: string, `revision`*: integer, `title`: string

### `POST /api/v1/notes/{id}/pin`

Pin Note By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/notes/{id}/update`

Update Note By Id

- parameters: `id` (path, string, required)
- body (application/json): `data`: object, `meta`: object, `page_generation`: integer, `page_id`: string, `page_operation`: NotePageOperation, `page_revision`: integer, `title`: string
