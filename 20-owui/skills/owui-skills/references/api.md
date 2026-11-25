# owui-skills API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/skills/`

Get Skills

- parameters: `query` (query, string)

### `POST /api/v1/skills/create`

Create New Skill

- body (application/json): `access_grants`: array<object>, `commit_message`: string, `content`: string, `data`: SkillData, `description`: string, `expected_version_id`: string, `files`: array<SkillFile>, `id`*: string, `is_active`: boolean, `meta`: SkillMeta, `name`*: string, `operations`: array<SkillFileOperation>

### `GET /api/v1/skills/export`

Export Skills

- parameters: `format` (query, string), `ids` (query, array<string>), `version_id` (query, string)

### `GET /api/v1/skills/id/{id}`

Get Skill By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/skills/id/{id}/access/update`

Update Skill Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `POST /api/v1/skills/id/{id}/clone`

Clone Skill

- parameters: `id` (path, string, required)
- body (application/json): `id`*: string, `name`*: string, `version_id`: string

### `DELETE /api/v1/skills/id/{id}/delete`

Delete Skill By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/skills/id/{id}/files`

Get Skill Files

- parameters: `id` (path, string, required), `version_id` (query, string)

### `GET /api/v1/skills/id/{id}/files/content`

Get Skill File

- parameters: `id` (path, string, required), `path` (query, string, required), `version_id` (query, string, required)

### `GET /api/v1/skills/id/{id}/history`

Get Skill History

- parameters: `id` (path, string, required), `page` (query, integer)

### `GET /api/v1/skills/id/{id}/history/diff`

Diff Skill History

- parameters: `id` (path, string, required), `from_id` (query, string, required), `to_id` (query, string, required)

### `GET /api/v1/skills/id/{id}/history/diff/file`

Diff Skill File

- parameters: `id` (path, string, required), `from_id` (query, string, required), `to_id` (query, string, required), `path` (query, string, required)

### `GET /api/v1/skills/id/{id}/history/{history_id}`

Get Skill History Entry

- parameters: `id` (path, string, required), `history_id` (path, string, required)

### `DELETE /api/v1/skills/id/{id}/history/{history_id}`

Delete Skill History Entry

- parameters: `id` (path, string, required), `history_id` (path, string, required)

### `POST /api/v1/skills/id/{id}/toggle`

Toggle Skill By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/skills/id/{id}/update`

Update Skill By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`: array<object>, `commit_message`: string, `content`: string, `data`: SkillData, `description`: string, `expected_version_id`: string, `files`: array<SkillFile>, `id`*: string, `is_active`: boolean, `meta`: SkillMeta, `name`*: string, `operations`: array<SkillFileOperation>

### `POST /api/v1/skills/id/{id}/update/version`

Set Skill Version

- parameters: `id` (path, string, required)
- body (application/json): `expected_version_id`*: string, `version_id`*: string

### `POST /api/v1/skills/import`

Import Skills

- body (multipart/form-data): `decisions`*: string, `files`*: array<string>

### `POST /api/v1/skills/import/preview`

Preview Skill Import

- body (multipart/form-data): `files`*: array<string>

### `GET /api/v1/skills/list`

Get Skill List

- parameters: `query` (query, string), `view_option` (query, string), `order_by` (query, string), `direction` (query, string), `page` (query, integer)

### `POST /api/v1/skills/load/url`

Load Skill By Url

- body (application/json): `url`*: string
