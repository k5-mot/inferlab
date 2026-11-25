# owui-comments API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/comments/`

List Resource Comments

- parameters: `resource_type` (query, string, required), `resource_id` (query, string, required), `cursor` (query, string), `limit` (query, integer), `anchored` (query, boolean)

### `POST /api/v1/comments/`

Create Comment

- body (application/json): `anchor`: CommentAnchor, `content`*: string, `resource_id`*: string, `resource_type`*: string, `target_id`: string, `target_type`: string, `temp_id`: string

### `GET /api/v1/comments/context`

Context

- parameters: `resource_type` (query, string, required), `resource_id` (query, string, required)

### `GET /api/v1/comments/mentions`

Mentions

- parameters: `resource_type` (query, string, required), `resource_id` (query, string, required), `query` (query, string)

### `GET /api/v1/comments/{id}`

Get Comment

- parameters: `id` (path, string, required)

### `PATCH /api/v1/comments/{id}`

Edit

- parameters: `id` (path, string, required)
- body (application/json): `content`*: string, `etag`*: string

### `DELETE /api/v1/comments/{id}`

Remove

- parameters: `id` (path, string, required), `etag` (query, string, required)

### `PUT /api/v1/comments/{id}/reactions`

Add Reaction

- parameters: `id` (path, string, required)
- body (application/json): `name`*: string

### `DELETE /api/v1/comments/{id}/reactions`

Remove Reaction

- parameters: `id` (path, string, required), `name` (query, string, required)

### `GET /api/v1/comments/{id}/replies`

Replies

- parameters: `id` (path, string, required), `cursor` (query, string), `limit` (query, integer)

### `POST /api/v1/comments/{id}/replies`

Reply

- parameters: `id` (path, string, required)
- body (application/json): `content`*: string, `reply_to_id`: string, `temp_id`: string
