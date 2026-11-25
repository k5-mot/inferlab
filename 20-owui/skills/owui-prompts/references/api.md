# owui-prompts API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/prompts/`

Get Prompts


### `POST /api/v1/prompts/create`

Create New Prompt

- body (application/json): `access_grants`: array<object>, `command`*: string, `commit_message`: string, `content`*: string, `data`: object, `is_production`: boolean, `meta`: object, `name`*: string, `tags`: array<string>, `version_id`: string

### `GET /api/v1/prompts/id/{prompt_id}`

Get Prompt By Id

- parameters: `prompt_id` (path, string, required)

### `POST /api/v1/prompts/id/{prompt_id}/access/update`

Update Prompt Access By Id

- parameters: `prompt_id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `DELETE /api/v1/prompts/id/{prompt_id}/delete`

Delete Prompt By Id

- parameters: `prompt_id` (path, string, required)

### `GET /api/v1/prompts/id/{prompt_id}/history`

Get Prompt History

- parameters: `prompt_id` (path, string, required), `page` (query, integer)

### `GET /api/v1/prompts/id/{prompt_id}/history/diff`

Get Prompt Diff

- parameters: `prompt_id` (path, string, required), `from_id` (query, string, required), `to_id` (query, string, required)

### `GET /api/v1/prompts/id/{prompt_id}/history/{history_id}`

Get Prompt History Entry

- parameters: `prompt_id` (path, string, required), `history_id` (path, string, required)

### `DELETE /api/v1/prompts/id/{prompt_id}/history/{history_id}`

Delete Prompt History Entry

- parameters: `prompt_id` (path, string, required), `history_id` (path, string, required)

### `POST /api/v1/prompts/id/{prompt_id}/toggle`

Toggle Prompt Active

- parameters: `prompt_id` (path, string, required)

### `POST /api/v1/prompts/id/{prompt_id}/update`

Update Prompt By Id

- parameters: `prompt_id` (path, string, required)
- body (application/json): `access_grants`: array<object>, `command`*: string, `commit_message`: string, `content`*: string, `data`: object, `is_production`: boolean, `meta`: object, `name`*: string, `tags`: array<string>, `version_id`: string

### `POST /api/v1/prompts/id/{prompt_id}/update/meta`

Update Prompt Metadata

- parameters: `prompt_id` (path, string, required)
- body (application/json): `command`*: string, `name`*: string, `tags`: array<string>

### `POST /api/v1/prompts/id/{prompt_id}/update/version`

Set Prompt Version

- parameters: `prompt_id` (path, string, required)
- body (application/json): `version_id`*: string

### `GET /api/v1/prompts/list`

Get Prompt List

- parameters: `query` (query, string), `view_option` (query, string), `tag` (query, string), `order_by` (query, string), `direction` (query, string), `page` (query, integer)

### `GET /api/v1/prompts/tags`

Get Prompt Tags
